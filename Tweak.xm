// PhotosVideoSpeed - 系统相册视频倍速播放
// 思路参考 MobileSlideShowHook：不 hook 系统类，仅在 com.apple.mobileslideshow 内
// 轮询扫描 CALayer 树找到可见的 AVPlayerLayer，对其 AVPlayer 施加公开 API rate。
// 支持 0.5x / 1x / 1.5x / 2x / 3x。
// UI：底部播放控制面板（播放/暂停 + 时间 + 进度条 + 倍速 + 收起按钮），
//     点 chevron.down 收起后只剩右下角 chevron.up 小按钮，点它展开。

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CMTime.h>
#import <QuartzCore/QuartzCore.h>

static NSArray<NSNumber *> *PSVSpeeds(void) {
    static NSArray<NSNumber *> *speeds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ speeds = @[ @0.5, @1.0, @1.5, @2.0, @3.0 ]; });
    return speeds;
}

static NSArray<NSString *> *PSVSpeedLabels(void) {
    static NSArray<NSString *> *labels;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ labels = @[@"0.5x", @"1x", @"1.5x", @"2x", @"3x"]; });
    return labels;
}

@interface PSVSpeedManager : NSObject
@property (nonatomic, strong) AVPlayer *player;            // 当前绑定的播放器
@property (nonatomic, assign) NSInteger speedIndex;        // 用户选定的倍速下标（默认 1 = 1x）
@property (nonatomic, strong) CADisplayLink *displayLink;  // 视频可见期间的低频守护（拦系统播放键重置）
@property (nonatomic, strong) NSTimer *scanTimer;          // 0.5s 兜底扫描（探测视频出现/消失）
@property (nonatomic, assign) BOOL appActive;

// 面板 UI
@property (nonatomic, strong) UIView *panelView;           // 底部控制面板
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UIButton *speedButton;       // "倍速"/"2x"
@property (nonatomic, strong) UIView *dividerView;
@property (nonatomic, strong) UIButton *collapseButton;    // 面板内 chevron.down
@property (nonatomic, strong) UIButton *expandButton;      // 收起后右下角 chevron.up
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *panelPlacement;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *expandPlacement;
@property (nonatomic, strong) NSLayoutConstraint *panelTopConstraint;  // 面板顶部锚在主视频下缘
@property (nonatomic, assign) CGRect videoFrameInWindow;               // 扫描得到的主视频层在窗口坐标中的位置
@property (nonatomic, assign) BOOL panelExpanded;          // 面板展开/收起（默认展开）

// 进度条拖动状态
@property (nonatomic, assign) BOOL userTracking;           // 正在拖进度条
@property (nonatomic, assign) BOOL resumeAfterScrub;       // 拖动前是否在播放
@end

@implementation PSVSpeedManager

+ (instancetype)sharedManager {
    static PSVSpeedManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[self alloc] init]; });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _speedIndex = 1;         // 1x
        _panelExpanded = YES;
    }
    return self;
}

- (double)userSpeed {
    return PSVSpeeds()[self.speedIndex].doubleValue;
}

#pragma mark - 引擎生命周期

- (void)startEngine {
    self.appActive = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [self startScanTimer];
    [self scanNow];
}

- (void)appDidBecomeActive {
    self.appActive = YES;
    [self startScanTimer];
    [self scanNow];
}

- (void)appWillResignActive {
    self.appActive = NO;
    [self stopScanTimer];
    self.displayLink.paused = YES;
}

- (void)startScanTimer {
    if (self.scanTimer) return;
    self.scanTimer = [NSTimer timerWithTimeInterval:0.5
                                             target:self
                                           selector:@selector(scanTimerFired:)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.scanTimer forMode:NSRunLoopCommonModes];
}

- (void)stopScanTimer {
    [self.scanTimer invalidate];
    self.scanTimer = nil;
}

- (void)scanTimerFired:(NSTimer *)timer {
    [self scanNow];
}

#pragma mark - 视频探测（轮询，无 hook）

- (NSArray<UIWindow *> *)visibleWindows {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isHidden && window.alpha > 0.02) [result addObject:window];
        }
    }
    return result;
}

// 迭代找 window 内可见且"像正片"的 AVPlayerLayer；返回子树里可见面积最大者及其在窗口坐标中的位置。
// 必须迭代 + 已访问集合：相册的 CALayer 树极深且可能成环，递归会打穿主栈（已导致线上 SIGSEGV）。
- (void)findPlayerLayerInWindow:(UIWindow *)window
                           best:(AVPlayerLayer **)bestOut
                           area:(double *)bestArea
                          frame:(CGRect *)frameOut {
    NSHashTable *visited = [NSHashTable weakObjectsHashTable];
    NSMutableArray<CALayer *> *stack = [NSMutableArray array];
    [stack addObject:window.layer];
    NSUInteger visitedCount = 0;
    while (stack.count > 0) {
        if (++visitedCount > 4096) return; // 层节点数保险丝
        CALayer *layer = [stack lastObject];
        [stack removeLastObject];
        if (!layer || [visited containsObject:layer]) continue;
        [visited addObject:layer];
        if (layer.isHidden || layer.opacity < 0.02) continue;

        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
            AVPlayer *player = ((AVPlayerLayer *)layer).player;
            AVPlayerItem *item = player.currentItem;
            if (player && item) {
                CGSize size = item.presentationSize;
                double duration = CMTimeGetSeconds(item.duration);
                // 有画面、时长 > 0.25s：排除实况照片预览和纯音频
                if (size.width > 1 && size.height > 1 && duration > 0.25) {
                    CALayer *rootLayer = window.layer;
                    CGRect rect = [layer convertRect:layer.bounds toLayer:rootLayer];
                    CGRect visible = CGRectIntersection(rect, rootLayer.bounds);
                    double area = visible.size.width * visible.size.height;
                    if (area > *bestArea) {
                        *bestArea = area;
                        *bestOut = (AVPlayerLayer *)layer;
                        *frameOut = visible;
                    }
                }
            }
        }

        for (CALayer *sub in layer.sublayers) {
            [stack addObject:sub];
        }
    }
}

- (void)scanNow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self scanNow]; });
        return;
    }
    if (!self.appActive) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;

    AVPlayerLayer *best = nil;
    double bestArea = 0;
    UIWindow *bestWindow = nil;
    CGRect bestFrame = CGRectZero;
    for (UIWindow *window in [self visibleWindows]) {
        AVPlayerLayer *found = nil;
        double area = 0;
        CGRect frame = CGRectZero;
        [self findPlayerLayerInWindow:window best:&found area:&area frame:&frame];
        // 全屏判定：层面积 ≥ 窗口 35%。网格里实况照片/视频的自动播放小预览直接出局
        double windowArea = window.bounds.size.width * window.bounds.size.height;
        if (found && windowArea > 0 && area >= windowArea * 0.35 && area > bestArea) {
            bestArea = area;
            best = found;
            bestWindow = window;
            bestFrame = frame;
        }
    }

    if (best && bestWindow) {
        AVPlayer *player = best.player;
        BOOL rebound = (player != self.player);
        self.player = player;
        self.videoFrameInWindow = bestFrame; // 面板用它锚定到主视频下缘
        if (rebound) [self applySpeed]; // 换了播放器：重新施加记忆倍速
        [self updateOverlayVisibilityInWindow:bestWindow];
        [self startDisplayLinkIfNeeded];
    } else {
        self.player = nil;
        [self updateOverlayVisibilityInWindow:nil];
        self.displayLink.paused = YES;
    }
}

#pragma mark - 倍速施加

- (void)applySpeed {
    AVPlayer *player = self.player;
    if (!player || player.rate == 0) return; // 暂停中只记忆不强设，播放时由 displayTick 兜底

    double target = self.userSpeed;
    AVPlayerItem *item = player.currentItem;
    if (item) {
        // 变速不变调算法只支持到 2x；3x 用 varispeed（音调随速度升高，类似快进听感）
        AVAudioTimePitchAlgorithm algorithm = (target > 2.0)
            ? AVAudioTimePitchAlgorithmVarispeed
            : AVAudioTimePitchAlgorithmTimeDomain;
        if (![item.audioTimePitchAlgorithm isEqualToString:algorithm]) {
            item.audioTimePitchAlgorithm = algorithm;
        }
    }
    if (player.rate != target) {
        player.rate = target;
    }
}

- (void)startDisplayLinkIfNeeded {
    if (!self.displayLink) {
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
        link.preferredFramesPerSecond = 15;
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self.displayLink = link;
    }
    self.displayLink.paused = NO;
}

- (void)displayTick:(CADisplayLink *)link {
    AVPlayer *player = self.player;
    if (!player || !self.appActive) {
        link.paused = YES;
        return;
    }
    // 系统播放键恢复播放时会把 rate 重置为 1.0：非 1x 选择下拦回用户倍速
    if (self.userSpeed != 1.0 && player.rate == 1.0) {
        [self applySpeed];
    }
    [self updatePlayButtonIcon];
}

#pragma mark - 面板 UI

- (UIImage *)symbol:(NSString *)name pointSize:(CGFloat)size {
    return [UIImage systemImageNamed:name
                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size]];
}

- (void)buildPanelIfNeeded {
    if (self.panelView) return;

    // 单行细条：高 28，全部控件垂直居中
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    panel.layer.cornerRadius = 14;
    panel.translatesAutoresizingMaskIntoConstraints = NO;

    // 播放/暂停
    UIButton *play = [UIButton buttonWithType:UIButtonTypeCustom];
    play.translatesAutoresizingMaskIntoConstraints = NO;
    play.tintColor = [UIColor whiteColor];
    [play setImage:[self symbol:@"play.fill" pointSize:14] forState:UIControlStateNormal];
    [play addTarget:self action:@selector(togglePlayPause) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:play];

    // 时间标签 00:03 / 00:21
    UILabel *time = [[UILabel alloc] initWithFrame:CGRectZero];
    time.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    time.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    time.text = @"00:00 / 00:00";
    time.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:time];

    // 进度条
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
    slider.minimumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.95];
    slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:self action:@selector(sliderTouchDown) forControlEvents:UIControlEventTouchDown];
    [slider addTarget:self action:@selector(sliderValueChanged) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderTouchEnded)
         forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [panel addSubview:slider];

    // 倍速按钮：1x 时显示"倍速"，其他倍速显示当前速度；点按循环，长按菜单直选
    UIButton *speed = [UIButton buttonWithType:UIButtonTypeCustom];
    speed.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [speed setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    speed.translatesAutoresizingMaskIntoConstraints = NO;
    [speed.widthAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
    [speed.heightAnchor constraintGreaterThanOrEqualToConstant:24].active = YES;
    [speed addTarget:self action:@selector(cycleSpeed) forControlEvents:UIControlEventTouchUpInside];
    [self rebuildMenuForButton:speed];
    [panel addSubview:speed];

    // 分隔线 + 收起按钮
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:divider];

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeCustom];
    collapse.tintColor = [UIColor whiteColor];
    [collapse setImage:[self symbol:@"chevron.down" pointSize:12] forState:UIControlStateNormal];
    collapse.translatesAutoresizingMaskIntoConstraints = NO;
    [collapse addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:collapse];

    [panel addConstraints:@[
        [play.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:8],
        [play.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
        [play.widthAnchor constraintEqualToConstant:24],
        [play.heightAnchor constraintEqualToConstant:24],

        [time.leadingAnchor constraintEqualToAnchor:play.trailingAnchor constant:6],
        [time.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],

        [slider.leadingAnchor constraintEqualToAnchor:time.trailingAnchor constant:6],
        [slider.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
        [slider.heightAnchor constraintEqualToConstant:20],

        [speed.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:2],
        [speed.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],

        [divider.leadingAnchor constraintEqualToAnchor:speed.trailingAnchor constant:4],
        [divider.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
        [divider.widthAnchor constraintEqualToConstant:1],
        [divider.heightAnchor constraintEqualToConstant:20],

        [collapse.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor constant:2],
        [collapse.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-2],
        [collapse.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
        [collapse.widthAnchor constraintEqualToConstant:28],
        [collapse.heightAnchor constraintEqualToConstant:28],
    ]];
    // 面板右缘由 collapse 撑住；slider 右缘贴 speed，time 右缘不强约束

    self.panelView = panel;
    self.playButton = play;
    self.timeLabel = time;
    self.slider = slider;
    self.speedButton = speed;
    self.dividerView = divider;
    self.collapseButton = collapse;

    // 收起态的展开按钮
    UIButton *expand = [UIButton buttonWithType:UIButtonTypeCustom];
    expand.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    expand.layer.cornerRadius = 9;
    expand.tintColor = [UIColor whiteColor];
    [expand setImage:[self symbol:@"chevron.up" pointSize:11] forState:UIControlStateNormal];
    expand.translatesAutoresizingMaskIntoConstraints = NO;
    expand.accessibilityLabel = @"展开播放面板";
    [expand addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [expand.widthAnchor constraintEqualToConstant:28].active = YES;
    [expand.heightAnchor constraintEqualToConstant:28].active = YES;
    self.expandButton = expand;

    [self updateSpeedButtonTitle];
}

- (void)updateOverlayVisibilityInWindow:(UIWindow *)window {
    [self buildPanelIfNeeded];

    // 无视频：全部隐藏
    if (!window) {
        [self fadeView:self.panelView hidden:YES];
        [self fadeView:self.expandButton hidden:YES];
        return;
    }

    // 挂载到目标窗口（窗口变化时迁移）
    if (self.panelView.window != window) {
        if (self.panelPlacement) [NSLayoutConstraint deactivateConstraints:self.panelPlacement];
        self.panelPlacement = nil;
        [self.panelView removeFromSuperview];
        [window addSubview:self.panelView];
        UILayoutGuide *safe = window.safeAreaLayoutGuide;
        self.panelTopConstraint = [self.panelView.topAnchor constraintEqualToAnchor:window.topAnchor constant:0];
        self.panelPlacement = @[
            [self.panelView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
            [self.panelView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
            self.panelTopConstraint,
            [self.panelView.heightAnchor constraintEqualToConstant:28],
        ];
        [NSLayoutConstraint activateConstraints:self.panelPlacement];
    }
    // 面板顶部锚到主视频下缘（细条压在预览条上方，不遮系统菜单）；
    // 视频接近满屏放不下时回退到底部安全区上方
    CGRect videoFrame = self.videoFrameInWindow;
    CGFloat desiredTop = CGRectGetMaxY(videoFrame) + 4;
    CGFloat maxTop = window.bounds.size.height - window.safeAreaInsets.bottom - 28 - 8;
    if (desiredTop > maxTop) desiredTop = maxTop;
    if (desiredTop < window.safeAreaInsets.top + 8) desiredTop = window.safeAreaInsets.top + 8;
    if (self.panelTopConstraint.constant != desiredTop) {
        self.panelTopConstraint.constant = desiredTop;
    }
    if (self.expandButton.window != window) {
        if (self.expandPlacement) [NSLayoutConstraint deactivateConstraints:self.expandPlacement];
        self.expandPlacement = nil;
        [self.expandButton removeFromSuperview];
        [window addSubview:self.expandButton];
        UILayoutGuide *safe = window.safeAreaLayoutGuide;
        self.expandPlacement = @[
            [self.expandButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
            [self.expandButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-20],
        ];
        [NSLayoutConstraint activateConstraints:self.expandPlacement];
    }

    [window bringSubviewToFront:self.panelView];
    [window bringSubviewToFront:self.expandButton];

    if (self.panelExpanded) {
        [self fadeView:self.panelView hidden:NO];
        [self fadeView:self.expandButton hidden:YES];
    } else {
        [self fadeView:self.panelView hidden:YES];
        [self fadeView:self.expandButton hidden:NO];
    }
    [self updateProgressNow];
}

- (void)fadeView:(UIView *)view hidden:(BOOL)hidden {
    if (!view || view.hidden == hidden) return;
    if (hidden) {
        [UIView animateWithDuration:0.18
            animations:^{ view.alpha = 0; }
            completion:^(BOOL finished) {
                if (finished) view.hidden = YES;
            }];
    } else {
        view.alpha = 0;
        view.hidden = NO;
        [UIView animateWithDuration:0.18 animations:^{ view.alpha = 1; }];
    }
}

- (void)togglePanel {
    self.panelExpanded = !self.panelExpanded;
    UIWindow *window = self.panelView.window ?: self.expandButton.window;
    [self updateOverlayVisibilityInWindow:window];
}

#pragma mark - 播放/暂停

- (void)togglePlayPause {
    AVPlayer *player = self.player;
    if (!player) return;
    if (player.rate != 0) {
        player.rate = 0;     // 暂停
    } else {
        [self applySpeed];   // 直接以用户倍速恢复，不走 play()（会把速度重置为 1x）
    }
    [self updatePlayButtonIcon];
}

- (void)updatePlayButtonIcon {
    AVPlayer *player = self.player;
    NSString *name = (player && player.rate != 0) ? @"pause.fill" : @"play.fill";
    UIImage *current = [self.playButton imageForState:UIControlStateNormal];
    if ([current.description rangeOfString:name].location == NSNotFound) {
        [self.playButton setImage:[self symbol:name pointSize:14] forState:UIControlStateNormal];
    }
}

#pragma mark - 进度条

- (NSString *)timeString:(double)seconds {
    if (!(seconds > 0)) seconds = 0; // 滤掉 NaN/负数
    long total = (long)seconds;
    if (total >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", total / 60, total % 60];
}

- (void)updateProgressNow {
    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;
    if (!player || !item) return;
    double duration = CMTimeGetSeconds(item.duration);
    if (!(duration > 0.25)) return;

    double t = CMTimeGetSeconds(player.currentTime);
    if (!(t >= 0)) t = 0;
    if (t > duration) t = duration;

    if (fabs(self.slider.maximumValue - duration) > 0.01) {
        [self.slider setMaximumValue:(float)duration];
    }
    if (!self.userTracking) {
        [self.slider setValue:(float)t animated:NO];
        NSString *text = [NSString stringWithFormat:@"%@ / %@",
                          [self timeString:t], [self timeString:duration]];
        if (![self.timeLabel.text isEqualToString:text]) self.timeLabel.text = text;
    }
    [self updatePlayButtonIcon];
}

- (void)sliderTouchDown {
    AVPlayer *player = self.player;
    if (!player) return;
    self.resumeAfterScrub = (player.rate != 0);
    if (self.resumeAfterScrub) [player pause]; // 暂停后 seek，松手按用户倍速恢复
    self.userTracking = YES;
}

- (void)sliderValueChanged {
    AVPlayer *player = self.player;
    if (!player || !self.userTracking) return;
    AVPlayerItem *item = player.currentItem;
    double duration = item ? CMTimeGetSeconds(item.duration) : 0;
    NSString *text = [NSString stringWithFormat:@"%@ / %@",
                      [self timeString:self.slider.value], [self timeString:duration]];
    self.timeLabel.text = text;
}

- (void)sliderTouchEnded {
    if (!self.userTracking) return;
    AVPlayer *player = self.player;
    if (!player) {
        self.userTracking = NO;
        return;
    }
    __weak typeof(self) weakSelf = self;
    double target = self.slider.value;
    [player seekToTime:CMTimeMakeWithSeconds(target, 600)
       toleranceBefore:kCMTimeZero
        toleranceAfter:kCMTimeZero
     completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.player != player) return; // 拖动期间换了播放器
            strongSelf.userTracking = NO;
            if (strongSelf.resumeAfterScrub) [strongSelf applySpeed]; // 按用户倍速恢复播放
            [strongSelf updateProgressNow];
        });
    }];
}

#pragma mark - 倍速

- (void)updateSpeedButtonTitle {
    // 1x 显示"倍速"（与设计稿一致），非 1x 显示当前速度
    NSString *title = (self.speedIndex == 1) ? @"倍速" : PSVSpeedLabels()[self.speedIndex];
    [self.speedButton setTitle:title forState:UIControlStateNormal];
}

- (void)rebuildMenuForButton:(UIButton *)button {
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    NSArray<NSString *> *labels = PSVSpeedLabels();
    for (NSInteger i = 0; i < (NSInteger)labels.count; i++) {
        NSInteger index = i;
        UIAction *action = [UIAction actionWithTitle:labels[index]
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction *_) {
            [self setSpeedIndex:index];
        }];
        action.state = (index == self.speedIndex) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    button.menu = [UIMenu menuWithTitle:@"" children:actions];
    button.showsMenuAsPrimaryAction = NO; // 点按循环切换，长按弹菜单直选
}

- (void)setSpeedIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)PSVSpeeds().count) return;
    // 必须直接写 ivar：speedIndex 的 setter 就是本方法，self.speedIndex = index 会无限递归（0.0.2 点按钮爆栈的根因）
    _speedIndex = index;
    [self updateSpeedButtonTitle];
    [self rebuildMenuForButton:self.speedButton];
    [self applySpeed];
}

- (void)cycleSpeed {
    [self setSpeedIndex:((self.speedIndex + 1) % (NSInteger)PSVSpeeds().count)];
}

@end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PSVSpeedManager sharedManager] startEngine];
    });
}

// PhotosVideoSpeed - 系统相册视频倍速播放
// 思路参考 MobileSlideShowHook：不 hook 系统类，仅在 com.apple.mobileslideshow 内
// 轮询扫描 CALayer 树找到可见的 AVPlayerLayer，对其 AVPlayer 施加公开 API rate。
// 支持倍速：0.5x / 1x / 1.5x / 2x / 3x。点按浮动按钮循环切换，长按弹菜单直选。

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
@property (nonatomic, strong) UIButton *speedButton;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *buttonConstraints;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, assign) BOOL appActive;
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
        _speedIndex = 1; // 1x
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

// 迭代找 window 内可见且"像正片"的 AVPlayerLayer；返回子树里可见面积最大者。
// 必须迭代 + 已访问集合：相册的 CALayer 树极深且可能成环，递归会打穿主栈（已导致线上 SIGSEGV）。
- (void)findPlayerLayerInWindow:(UIWindow *)window
                           best:(AVPlayerLayer **)bestOut
                           area:(double *)bestArea {
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
    for (UIWindow *window in [self visibleWindows]) {
        AVPlayerLayer *found = nil;
        double area = 0;
        [self findPlayerLayerInWindow:window best:&found area:&area];
        // 全屏判定：层面积 ≥ 窗口 35%。网格里实况照片/视频的自动播放小预览直接出局
        double windowArea = window.bounds.size.width * window.bounds.size.height;
        if (found && windowArea > 0 && area >= windowArea * 0.35 && area > bestArea) {
            bestArea = area;
            best = found;
            bestWindow = window;
        }
    }

    if (best && bestWindow) {
        AVPlayer *player = best.player;
        BOOL rebound = (player != self.player);
        self.player = player;
        self.hostWindow = bestWindow;
        if (rebound) [self applySpeed]; // 换了播放器：重新施加记忆倍速
        [self showButtonInWindow:bestWindow];
        [self startDisplayLinkIfNeeded];
    } else {
        self.player = nil;
        self.hostWindow = nil;
        [self hideButton];
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
}

#pragma mark - 浮动倍速按钮

- (void)showButtonInWindow:(UIWindow *)window {
    if (!window) return;

    if (!self.speedButton) {
        // 固定尺寸胶囊：黑 60% 底 + 白色等宽字。不用自适应尺寸（不同系统版本下会被撑成大方块）
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
        button.layer.cornerRadius = 13;
        button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.accessibilityLabel = @"相册视频倍速";
        [button addTarget:self action:@selector(cycleSpeed) forControlEvents:UIControlEventTouchUpInside];
        [self rebuildMenuForButton:button];
        [button.widthAnchor constraintEqualToConstant:46].active = YES;
        [button.heightAnchor constraintEqualToConstant:26].active = YES;
        self.speedButton = button;
    }

    if (self.speedButton.window != window) {
        if (self.buttonConstraints) [NSLayoutConstraint deactivateConstraints:self.buttonConstraints];
        self.buttonConstraints = nil;
        [self.speedButton removeFromSuperview];
        [window addSubview:self.speedButton];
        UILayoutGuide *safe = window.safeAreaLayoutGuide;
        self.buttonConstraints = @[
            [self.speedButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
            [self.speedButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-48],
        ];
        [NSLayoutConstraint activateConstraints:self.buttonConstraints];
    }

    self.speedButton.hidden = NO;
    self.speedButton.alpha = 1;
    [window bringSubviewToFront:self.speedButton];
    [self updateButtonTitle];
}

- (void)hideButton {
    UIButton *button = self.speedButton;
    if (!button || button.hidden) return;
    [UIView animateWithDuration:0.15
        animations:^{ button.alpha = 0; }
        completion:^(BOOL finished) {
            if (finished) button.hidden = YES;
        }];
}

- (void)updateButtonTitle {
    [self.speedButton setTitle:PSVSpeedLabels()[self.speedIndex] forState:UIControlStateNormal];
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
    [self updateButtonTitle];
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

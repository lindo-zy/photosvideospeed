#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

static NSUInteger checks;
static void Check(BOOL success, NSString *message) {
    checks++;
    if (!success) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

typedef NSUInteger UIViewAnimationOptions;
static const UIViewAnimationOptions UIViewAnimationOptionBeginFromCurrentState = 1 << 2;
static const UIViewAnimationOptions UIViewAnimationOptionAllowUserInteraction = 1 << 1;
static NSMutableArray *animationCompletions;
static NSMutableArray *mainCallbacks;

// Apply the animation now, then allow tests to finish its callback after a
// later visibility request, reproducing the hide/show race deterministically.
@interface UIView : NSObject
@property (nonatomic) BOOL hidden;
@property (nonatomic) double alpha;
@property (nonatomic, strong) CALayer *layer;
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay
                    options:(UIViewAnimationOptions)options animations:(void (^)(void))animations
                 completion:(void (^)(BOOL finished))completion;
@end
@implementation UIView
- (CALayer *)layer {
    if (!_layer) _layer = [[CALayer alloc] init];
    return _layer;
}
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay
                    options:(UIViewAnimationOptions)options animations:(void (^)(void))animations
                 completion:(void (^)(BOOL finished))completion {
    (void)duration;
    (void)delay;
    Check((options & UIViewAnimationOptionBeginFromCurrentState) != 0, @"fade starts from current visual state");
    Check((options & UIViewAnimationOptionAllowUserInteraction) != 0, @"fade permits user interaction");
    animations();
    [animationCompletions addObject:[completion copy]];
}
@end

@interface UISlider : NSObject
@property (nonatomic) NSUInteger cancelCount;
@property (nonatomic) float value;
- (void)cancelTrackingWithEvent:(id)event;
@end
@implementation UISlider
- (void)cancelTrackingWithEvent:(id)event { (void)event; self.cancelCount++; }
@end

@interface TestSeekPlayer : AVPlayer
@property (nonatomic, strong) AVPlayerItem *testItem;
@property (nonatomic) float testRate;
@property (nonatomic) CMTime seekTarget;
@property (nonatomic, strong) NSMutableArray *seekCompletions;
- (void)finishSeek:(BOOL)finished;
@end
@implementation TestSeekPlayer
- (AVPlayerItem *)currentItem { return self.testItem; }
- (float)rate { return self.testRate; }
- (void)setRate:(float)rate { self.testRate = rate; }
- (void)seekToTime:(CMTime)time toleranceBefore:(CMTime)before toleranceAfter:(CMTime)after
 completionHandler:(void (^)(BOOL finished))completion {
    (void)before;
    (void)after;
    self.seekTarget = time;
    [self.seekCompletions addObject:[completion copy]];
}
- (void)finishSeek:(BOOL)finished {
    Check(self.seekCompletions.count > 0, @"fixture has a pending seek completion");
    void (^completion)(BOOL) = self.seekCompletions.firstObject;
    [self.seekCompletions removeObjectAtIndex:0];
    completion(finished);
}
@end

static void PSVTestDispatchAsync(dispatch_queue_t queue, dispatch_block_t block) {
    Check(queue == dispatch_get_main_queue(), @"seek completion schedules UI work on the main queue");
    [mainCallbacks addObject:[block copy]];
}

@interface PSVTestManager : NSObject
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic) NSUInteger playbackGeneration;
@property (nonatomic) NSUInteger scrubGeneration;
@property (nonatomic) BOOL userTracking;
@property (nonatomic) BOOL resumeAfterScrub;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIView *expandButton;
@property (nonatomic, weak) AVPlayerLayer *videoLayer;
@property (nonatomic) BOOL panelHiddenRequested;
@property (nonatomic) BOOL expandHiddenRequested;
@property (nonatomic) NSUInteger resumeCount;
@property (nonatomic) NSUInteger progressCount;
- (BOOL)bindPlayer:(AVPlayer *)player;
- (void)fadeView:(UIView *)view hidden:(BOOL)hidden;
- (void)hideViewNow:(UIView *)view;
- (BOOL)videoLayerIsGone;
- (void)sliderTouchEnded;
- (void)forceRateToUserSpeed;
- (void)updateProgressNow;
@end
@implementation PSVTestManager
// Exactly the original method text is extracted at test time. Only UIKit's
// animation scheduling and GCD completion delivery are controlled by stubs.
#define dispatch_async PSVTestDispatchAsync
#include "ProductionManagerMethods.inc"
#undef dispatch_async
- (void)forceRateToUserSpeed { self.resumeCount++; self.player.rate = 2; }
- (void)updateProgressNow { self.progressCount++; }
@end

static AVPlayerItem *Item(void) {
    return [[AVPlayerItem alloc] initWithAsset:[AVMutableComposition composition]];
}

static TestSeekPlayer *Player(void) {
    TestSeekPlayer *player = [[TestSeekPlayer alloc] init];
    player.testItem = Item();
    player.seekCompletions = [NSMutableArray array];
    return player;
}

static PSVTestManager *Manager(void) {
    PSVTestManager *manager = [[PSVTestManager alloc] init];
    manager.slider = [[UISlider alloc] init];
    manager.panelView = [[UIView alloc] init];
    manager.expandButton = [[UIView alloc] init];
    manager.panelView.hidden = YES;
    manager.expandButton.hidden = YES;
    manager.panelHiddenRequested = YES;
    manager.expandHiddenRequested = YES;
    return manager;
}

static void DrainMainCallbacks(void) {
    while (mainCallbacks.count) {
        dispatch_block_t callback = mainCallbacks.firstObject;
        [mainCallbacks removeObjectAtIndex:0];
        callback();
    }
}

static void CompleteAnimation(NSUInteger index, BOOL finished) {
    void (^completion)(BOOL) = animationCompletions[index];
    completion(finished);
}

static void TestBinding(void) {
    PSVTestManager *manager = Manager();
    TestSeekPlayer *first = Player(), *second = Player();
    manager.userTracking = YES;
    manager.resumeAfterScrub = YES;
    Check([manager bindPlayer:first], @"initial player binding reports change");
    Check(manager.playerItem == first.currentItem && manager.playbackGeneration == 1 && manager.scrubGeneration == 1,
          @"initial binding records item and advances both callback generations");
    Check(!manager.userTracking && !manager.resumeAfterScrub && manager.slider.cancelCount == 1,
          @"binding clears drag state and cancels slider tracking");
    manager.userTracking = YES;
    manager.resumeAfterScrub = YES;
    Check(![manager bindPlayer:first] && manager.playbackGeneration == 1 && manager.slider.cancelCount == 1 &&
          manager.userTracking && manager.resumeAfterScrub,
          @"same player and item leave callback generation and tracking untouched");
    first.testItem = Item();
    manager.userTracking = YES;
    manager.resumeAfterScrub = YES;
    Check([manager bindPlayer:first] && manager.playerItem == first.currentItem && manager.playbackGeneration == 2,
          @"same AVPlayer with replacement item is rebound");
    Check(!manager.userTracking && !manager.resumeAfterScrub && manager.scrubGeneration == 2,
          @"replacement item invalidates drag state and seek generation");
    Check([manager bindPlayer:second] && manager.player == second && manager.playbackGeneration == 3,
          @"switching AVPlayer is rebound");
    Check([manager bindPlayer:nil] && manager.player == nil && manager.playerItem == nil && manager.playbackGeneration == 4,
          @"leaving video clears player/item and invalidates callbacks");
    Check(![manager bindPlayer:nil] && manager.playbackGeneration == 4,
          @"repeated no-video scans do not keep advancing callback generations");
}

static void TestFadeRace(void) {
    [animationCompletions removeAllObjects];
    PSVTestManager *manager = Manager();
    [manager fadeView:manager.panelView hidden:NO];
    [manager fadeView:manager.panelView hidden:YES];
    [manager fadeView:manager.panelView hidden:NO];
    Check(animationCompletions.count == 3 && !manager.panelView.hidden && manager.panelView.alpha == 1,
          @"hide followed by show reverses an unfinished fade");
    CompleteAnimation(1, YES);
    Check(!manager.panelView.hidden && !manager.panelHiddenRequested,
          @"old hide completion cannot hide the panel of the next video");
    NSUInteger count = animationCompletions.count;
    [manager fadeView:manager.panelView hidden:NO];
    Check(animationCompletions.count == count, @"repeated visible scans do not create duplicate animations");

    [manager fadeView:manager.expandButton hidden:NO];
    [manager fadeView:manager.expandButton hidden:YES];
    [manager fadeView:manager.expandButton hidden:NO];
    CompleteAnimation(4, YES);
    Check(!manager.expandButton.hidden && !manager.expandHiddenRequested && !manager.panelHiddenRequested,
          @"expand-button visibility uses an independent request state and rejects old hide completion");
    [manager fadeView:manager.panelView hidden:YES];
    CompleteAnimation(6, NO);
    Check(!manager.panelView.hidden, @"cancelled hide animation does not set hidden");
    [manager fadeView:manager.panelView hidden:NO];
    [manager fadeView:manager.panelView hidden:YES];
    CompleteAnimation(8, YES);
    Check(manager.panelView.hidden && manager.panelView.alpha == 0, @"current successful hide completion hides the panel");
    count = animationCompletions.count;
    [manager fadeView:nil hidden:YES];
    Check(animationCompletions.count == count, @"nil view is safely ignored");
}

static void TestInstantHide(void) {
    [animationCompletions removeAllObjects];
    PSVTestManager *manager = Manager();
    [manager fadeView:manager.panelView hidden:NO];
    [manager fadeView:manager.expandButton hidden:NO];
    [manager hideViewNow:manager.panelView];
    Check(manager.panelHiddenRequested && manager.panelView.hidden && manager.panelView.alpha == 0,
          @"leaving the video hides the panel in the same frame without fading");
    [manager hideViewNow:manager.expandButton];
    Check(manager.expandHiddenRequested && manager.expandButton.hidden && manager.expandButton.alpha == 0,
          @"leaving the video hides the expand button in the same frame without fading");
    CompleteAnimation(0, YES);
    CompleteAnimation(1, YES);
    Check(manager.panelView.hidden && manager.panelHiddenRequested &&
          manager.expandButton.hidden && manager.expandHiddenRequested,
          @"in-flight fade completions cannot resurrect views hidden by leaving the video");
    [manager fadeView:manager.panelView hidden:NO];
    Check(!manager.panelHiddenRequested && !manager.panelView.hidden && manager.panelView.alpha == 1,
          @"a later video fades the instantly hidden panel back in");
    NSUInteger count = animationCompletions.count;
    [manager hideViewNow:nil];
    Check(animationCompletions.count == count, @"nil view is safely ignored by hideViewNow");
}

static void TestVideoLayerGone(void) {
    PSVTestManager *manager = Manager();
    manager.player = Player(); // 探测只在已绑定播放器时进行
    CALayer *root = [[CALayer alloc] init];
    AVPlayerLayer *layer = [[AVPlayerLayer alloc] init];
    layer.player = manager.player;
    [root addSublayer:layer];
    manager.videoLayer = layer;
    Check(![manager videoLayerIsGone], @"attached bound video layer counts as visible");
    [layer removeFromSuperlayer];
    Check([manager videoLayerIsGone], @"detached video layer is gone");
    [root addSublayer:layer];
    Check(![manager videoLayerIsGone], @"reattached video layer counts as visible");
    layer.hidden = YES;
    Check([manager videoLayerIsGone], @"hidden video layer is gone");
    layer.hidden = NO;
    layer.opacity = 0.01;
    Check([manager videoLayerIsGone], @"fully transparent video layer is gone");
    layer.opacity = 1;
    layer.player = nil;
    Check([manager videoLayerIsGone], @"video layer whose player detached is gone");
    layer.player = manager.player;
    manager.videoLayer = nil;
    Check([manager videoLayerIsGone], @"released video layer is gone");
    manager.player = nil;
    manager.videoLayer = layer;
    Check(![manager videoLayerIsGone], @"unbound manager skips the probe instead of rescanning");
}

static void BeginSeek(PSVTestManager *manager, float target, BOOL resume) {
    manager.userTracking = YES;
    manager.resumeAfterScrub = resume;
    manager.scrubGeneration++;
    manager.slider.value = target;
    [manager sliderTouchEnded];
}

static void TestSeekSwitching(void) {
    PSVTestManager *manager = Manager();
    TestSeekPlayer *first = Player(), *second = Player();
    [manager bindPlayer:first];
    BeginSeek(manager, 13, YES);
    Check(CMTimeGetSeconds(first.seekTarget) == 13 && manager.userTracking,
          @"drag end seeks to the selected time and awaits completion");
    [manager bindPlayer:second];
    [first finishSeek:YES];
    DrainMainCallbacks();
    Check(manager.resumeCount == 0 && manager.progressCount == 0 && second.rate == 0,
          @"old player seek completion cannot resume or update the next video");

    BeginSeek(manager, 17, YES);
    [second finishSeek:YES];
    DrainMainCallbacks();
    Check(manager.resumeCount == 1 && manager.progressCount == 1 && second.rate == 2 &&
          !manager.userTracking && !manager.resumeAfterScrub,
          @"current successful seek restores chosen playback speed and clears drag state");

    BeginSeek(manager, 19, YES);
    second.testItem = Item();
    [manager bindPlayer:second];
    [second finishSeek:YES];
    DrainMainCallbacks();
    Check(manager.resumeCount == 1 && manager.progressCount == 1,
          @"same player's old item seek completion is invalidated by replacement-item binding");

    BeginSeek(manager, 23, YES);
    second.testItem = Item();
    [second finishSeek:YES];
    DrainMainCallbacks();
    Check(manager.resumeCount == 1 && manager.progressCount == 1 && manager.userTracking,
          @"currentItem identity check rejects an item change before the next scan");
    [manager bindPlayer:second];

    BeginSeek(manager, 29, YES);
    BeginSeek(manager, 31, NO);
    [second finishSeek:YES];
    DrainMainCallbacks();
    Check(manager.userTracking && manager.resumeCount == 1 && manager.progressCount == 1,
          @"prior drag completion cannot end a newer drag");
    [second finishSeek:YES];
    DrainMainCallbacks();
    Check(!manager.userTracking && manager.resumeCount == 1 && manager.progressCount == 2,
          @"latest paused seek completes without resuming playback");

    BeginSeek(manager, 37, YES);
    [second finishSeek:NO];
    DrainMainCallbacks();
    Check(!manager.userTracking && !manager.resumeAfterScrub && manager.resumeCount == 1 && manager.progressCount == 3,
          @"failed current seek clears drag state without resuming playback");
    BeginSeek(manager, 41, YES);
    [manager bindPlayer:nil];
    [second finishSeek:YES];
    DrainMainCallbacks();
    Check(manager.player == nil && manager.resumeCount == 1 && manager.progressCount == 3,
          @"leaving videos invalidates pending seeks");
}

int main(void) {
    @autoreleasepool {
        animationCompletions = [NSMutableArray array];
        mainCallbacks = [NSMutableArray array];
        TestBinding();
        TestFadeRace();
        TestInstantHide();
        TestVideoLayerGone();
        TestSeekSwitching();
        printf("PASS: production manager methods with UIKit scheduling stubs (%lu assertions)\n", (unsigned long)checks);
    }
    return 0;
}

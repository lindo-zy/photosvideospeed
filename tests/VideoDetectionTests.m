#import <Foundation/Foundation.h>
#import "../PSVVideoDetection.h"

// Keep real CALayer geometry and traversal. Only AVFoundation loading getters
// are replaced, so every assertion runs the exact production detector.
@interface TestPlayerItem : AVPlayerItem
@property (nonatomic) AVPlayerItemStatus testStatus;
@end
@implementation TestPlayerItem
- (AVPlayerItemStatus)status { return self.testStatus; }
- (CGSize)presentationSize { return CGSizeZero; }
- (CMTime)duration { return kCMTimeIndefinite; }
@end

@interface TestPlayer : AVPlayer
@property (nonatomic, strong) AVPlayerItem *testItem;
@end
@implementation TestPlayer
- (AVPlayerItem *)currentItem { return self.testItem; }
- (float)rate { return 0; }
@end

@interface TestPlayerLayer : AVPlayerLayer
@property (nonatomic, strong) AVPlayer *testPlayer;
@property (nonatomic) CGRect testVideoRect;
@end
@implementation TestPlayerLayer
- (AVPlayer *)player { return self.testPlayer; }
- (CGRect)videoRect { return self.testVideoRect; }
@end

static NSUInteger checks;
static void Check(BOOL success, NSString *message) {
    checks++;
    if (!success) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static BOOL RectNear(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.001 &&
        fabs(a.origin.y - b.origin.y) < 0.001 &&
        fabs(a.size.width - b.size.width) < 0.001 &&
        fabs(a.size.height - b.size.height) < 0.001;
}

static CALayer *Root(void) {
    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0, 0, 390, 844);
    return root;
}

static TestPlayerLayer *Video(CGRect frame) {
    TestPlayerItem *item = [[TestPlayerItem alloc] initWithAsset:[AVMutableComposition composition]];
    item.testStatus = AVPlayerItemStatusUnknown;
    TestPlayer *player = [[TestPlayer alloc] init];
    player.testItem = item;
    TestPlayerLayer *layer = [TestPlayerLayer layer];
    layer.testPlayer = player;
    layer.frame = frame;
    return layer;
}

static void TestLandscapeAndUnloadedPausedItem(void) {
    CALayer *root = Root();
    CGRect frame = CGRectMake(0, (844 - 390 * 9.0 / 16) / 2, 390, 390 * 9.0 / 16);
    TestPlayerLayer *video = Video(frame);
    [root addSublayer:video];
    Check(frame.size.width * frame.size.height / (390 * 844) < 0.35,
          @"fixture is a full-width 16:9 video below the old 35% area threshold");
    Check(video.player.rate == 0 && CGSizeEqualToSize(video.player.currentItem.presentationSize, CGSizeZero) &&
          CMTIME_IS_INDEFINITE(video.player.currentItem.duration), @"fixture is paused and metadata is unloaded");
    CGRect detected = CGRectZero;
    Check(PSVFindMainVideoLayer(root, &detected) == video, @"paused, unloaded landscape video is detected");
    Check(RectNear(detected, frame), @"unloaded video uses the visible player bounds for panel placement");
    Check(PSVFindMainVideoLayer(root, NULL) == video, @"optional output pointer may be NULL");
    video.frame = CGRectMake(0, 170, 390, 390 * 9.0 / 16);
    Check(PSVFindMainVideoLayer(root, NULL) == video,
          @"full-width video remains eligible when Photos toolbars shift its vertical center");
}

static void TestClippingAndOverflow(void) {
    CALayer *root = Root();
    CALayer *cachedPage = [CALayer layer];
    cachedPage.frame = CGRectMake(5000, 0, 390, 844);
    cachedPage.masksToBounds = YES;
    TestPlayerLayer *video = Video(CGRectMake(-5000, 300, 390, 244));
    [cachedPage addSublayer:video];
    [root addSublayer:cachedPage];
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"offscreen clipping ancestor excludes a cached player");
    cachedPage.masksToBounds = NO;
    Check(PSVFindMainVideoLayer(root, NULL) == video,
          @"offscreen non-clipping ancestor permits its visible overflowing child");

    CALayer *clip = [CALayer layer];
    clip.frame = CGRectMake(0, 280, 390, 260);
    clip.masksToBounds = YES;
    [video removeFromSuperlayer];
    video.frame = CGRectMake(0, -80, 390, 420);
    video.testVideoRect = CGRectMake(0, 0, 390, 340);
    [clip addSublayer:video];
    [root addSublayer:clip];
    CGRect detected = CGRectZero;
    Check(PSVFindMainVideoLayer(root, &detected) == video, @"partially clipped main video stays detectable");
    Check(RectNear(detected, CGRectMake(0, 280, 390, 260)),
          @"panel anchor intersects videoRect with every ancestor clip");
    video.testVideoRect = CGRectMake(0, 100, 390, 220);
    PSVFindMainVideoLayer(root, &detected);
    Check(RectNear(detected, CGRectMake(0, 300, 390, 220)),
          @"letterboxed videoRect is converted into window coordinates");
    video.testVideoRect = CGRectZero;
    PSVFindMainVideoLayer(root, &detected);
    Check(RectNear(detected, CGRectMake(0, 280, 390, 260)),
          @"empty videoRect falls back to clipped layer bounds");
}

static void TestVisibility(void) {
    CALayer *root = Root();
    CALayer *parent = [CALayer layer];
    parent.frame = root.bounds;
    TestPlayerLayer *video = Video(CGRectMake(0, 300, 390, 244));
    [parent addSublayer:video];
    [root addSublayer:parent];
    video.hidden = YES;
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"hidden player is excluded");
    video.hidden = NO;
    parent.hidden = YES;
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"hidden ancestor excludes its player");
    parent.hidden = NO;
    parent.opacity = 0.1;
    video.opacity = 0.1;
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"inherited opacity product below 0.02 is excluded");
    parent.opacity = 0.5;
    Check(PSVFindMainVideoLayer(root, NULL) == video, @"visible opacity product preserves the player");
    root.opacity = 0.01;
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"root opacity participates in visibility");
}

static void TestThumbnailsAndGrid(void) {
    CALayer *root = Root();
    [root addSublayer:Video(CGRectMake(120, 760, 150, 70))];
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"bottom video thumbnail never creates a panel");
    [root addSublayer:Video(CGRectMake(0, 760, 390, 40))];
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"full-width thin thumbnail strip never creates a panel");
    [root addSublayer:Video(CGRectMake(105, 312, 180, 220))];
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"small central grid tile is not a main video");
    [root addSublayer:Video(CGRectMake(10, 40, 180, 220))];
    [root addSublayer:Video(CGRectMake(200, 40, 180, 220))];
    [root addSublayer:Video(CGRectMake(10, 580, 180, 220))];
    [root addSublayer:Video(CGRectMake(200, 580, 180, 220))];
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"video grid has no eligible main video");
    [root addSublayer:Video(CGRectMake(350, 200, 390, 390))];
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"large off-center cached page is excluded");
}

static void TestLargeLayerTree(void) {
    CALayer *root = Root();
    TestPlayerLayer *video = Video(CGRectMake(0, 300, 390, 244));
    [root addSublayer:video];
    // The detector uses a LIFO stack; adding these later ensures the main
    // player is visited after 6000 other layers, past the former scan cap.
    for (NSUInteger i = 0; i < 6000; i++) [root addSublayer:[CALayer layer]];
    double total = 0, maximum = 0;
    BOOL allFound = YES;
    for (NSUInteger i = 0; i < 20; i++) {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        allFound = allFound && PSVFindMainVideoLayer(root, NULL) == video;
        double elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        total += elapsed;
        maximum = fmax(maximum, elapsed);
    }
    Check(allFound, @"video after more than 4096 scanned layers is found");
    printf("INFO: 6002-layer scan, 20 runs on macOS: mean %.2f ms, max %.2f ms\n", total / 20, maximum);
}

static void TestSwitchingAndItems(void) {
    CALayer *root = Root();
    TestPlayerLayer *first = Video(CGRectMake(0, 300, 390, 244));
    TestPlayerLayer *second = Video(first.frame);
    second.hidden = YES;
    [root addSublayer:first];
    [root addSublayer:second];
    Check(PSVFindMainVideoLayer(root, NULL) == first, @"first visible video is detected");
    first.hidden = YES;
    second.hidden = NO;
    Check(PSVFindMainVideoLayer(root, NULL) == second, @"switching visibility selects the next video");
    second.hidden = YES;
    first.hidden = NO;
    Check(PSVFindMainVideoLayer(root, NULL) == first, @"switching back selects the original video");
    ((TestPlayerItem *)first.player.currentItem).testStatus = AVPlayerItemStatusFailed;
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"failed player item is excluded");
    ((TestPlayer *)first.player).testItem = nil;
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"nil player item is excluded");
    first.testPlayer = nil;
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"nil player is excluded");
    CGRect detected = CGRectMake(1, 2, 3, 4);
    PSVFindMainVideoLayer(root, &detected);
    Check(CGRectEqualToRect(detected, CGRectZero), @"a detection miss resets the output frame");
}

static void TestRectEligibilityAndSelection(void) {
    CGRect viewport = CGRectMake(0, 0, 390, 844);
    Check(PSVIsMainVideoRect(CGRectMake(0, 388, 390, 68), viewport), @"centered panoramic video qualifies by width");
    Check(PSVIsMainVideoRect(CGRectMake(175, 0, 40, 844), viewport), @"centered tall video qualifies by height");
    Check(!PSVIsMainVideoRect(CGRectNull, viewport), @"null rectangle is ineligible");
    Check(!PSVIsMainVideoRect(CGRectMake(0, 0, NAN, 844), viewport), @"nonfinite rectangle is ineligible");
    Check(!PSVIsMainVideoRect(viewport, CGRectZero), @"empty viewport is ineligible");
    CALayer *root = Root();
    TestPlayerLayer *small = Video(CGRectMake(0, 300, 390, 244));
    TestPlayerLayer *large = Video(CGRectMake(0, 150, 390, 544));
    [root addSublayer:large];
    [root addSublayer:small];
    Check(PSVFindMainVideoLayer(root, NULL) == large, @"largest eligible visible video wins independent of scan order");
    CGRect detected = CGRectMake(1, 2, 3, 4);
    Check(PSVFindMainVideoLayer(nil, &detected) == nil && CGRectEqualToRect(detected, CGRectZero),
          @"nil root is safely rejected and resets output");
    root.bounds = CGRectZero;
    Check(PSVFindMainVideoLayer(root, NULL) == nil, @"empty root is safely rejected");
}

int main(void) {
    @autoreleasepool {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        TestLandscapeAndUnloadedPausedItem();
        TestClippingAndOverflow();
        TestVisibility();
        TestThumbnailsAndGrid();
        TestLargeLayerTree();
        TestSwitchingAndItems();
        TestRectEligibilityAndSelection();
        [CATransaction commit];
        printf("PASS: video detection (%lu assertions)\n", (unsigned long)checks);
    }
    return 0;
}

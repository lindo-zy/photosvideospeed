#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static BOOL PSVHasVisibleRect(CGRect rect) {
    return !CGRectIsNull(rect) && !CGRectIsEmpty(rect) &&
        isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height);
}

// 层面积不能单独判定全屏：竖屏窗口里的横屏视频可能只占窗口约 1/4。
// 同时要求跨过窗口横向中心，避免绑定到左右缓存页；不限制纵向中心，
// 因为工具栏/安全区会使横屏视频的内容中心偏离窗口中心。
static BOOL PSVIsMainVideoRect(CGRect rect, CGRect viewport) {
    if (!PSVHasVisibleRect(rect) || !PSVHasVisibleRect(viewport)) return NO;
    CGFloat centerX = CGRectGetMidX(viewport);
    if (CGRectGetMinX(rect) >= centerX || CGRectGetMaxX(rect) <= centerX) return NO;
    double widthFraction = rect.size.width / viewport.size.width;
    double heightFraction = rect.size.height / viewport.size.height;
    return widthFraction * heightFraction >= 0.35 ||
        (widthFraction >= 0.75 && heightFraction >= 0.08) ||
        (heightFraction >= 0.75 && widthFraction >= 0.08);
}

// 只供迭代扫描使用；继承父层的裁剪区和有效透明度。
@interface PSVVideoScanEntry : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, assign) CGRect clipRect;
@property (nonatomic, assign) float opacity;
@end

@implementation PSVVideoScanEntry
@end

static AVPlayerLayer *PSVFindMainVideoLayer(CALayer *rootLayer, CGRect *frameOut) {
    if (frameOut) *frameOut = CGRectZero;
    if (!rootLayer || !PSVHasVisibleRect(rootLayer.bounds)) return nil;

    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray<PSVVideoScanEntry *> *stack = [NSMutableArray array];
    PSVVideoScanEntry *root = [[PSVVideoScanEntry alloc] init];
    root.layer = rootLayer;
    root.clipRect = rootLayer.bounds;
    root.opacity = 1;
    [stack addObject:root];

    AVPlayerLayer *best = nil;
    double bestArea = 0;
    while (stack.count > 0) {
        PSVVideoScanEntry *entry = stack.lastObject;
        [stack removeLastObject];
        CALayer *layer = entry.layer;
        if (!layer || [visited containsObject:layer]) continue;
        [visited addObject:layer];
        float opacity = entry.opacity * layer.opacity;
        if (layer.isHidden || opacity < 0.02) continue;

        CGRect clipRect = entry.clipRect;
        if (layer.masksToBounds) {
            CGRect bounds = [layer convertRect:layer.bounds toLayer:rootLayer];
            clipRect = CGRectIntersection(clipRect, bounds);
            if (!PSVHasVisibleRect(clipRect)) continue;
        }

        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
            AVPlayerLayer *playerLayer = (AVPlayerLayer *)layer;
            AVPlayerItem *item = playerLayer.player.currentItem;
            // presentationSize/duration 未加载时分别是零/indefinite；不能据此隐藏面板。
            // 暂停/首次切入的视频同样可以先绑定，进度信息在加载后刷新。
            if (item && item.status != AVPlayerItemStatusFailed) {
                CGRect rect = [layer convertRect:layer.bounds toLayer:rootLayer];
                CGRect visible = CGRectIntersection(rect, clipRect);
                if (PSVIsMainVideoRect(visible, rootLayer.bounds)) {
                    double area = visible.size.width * visible.size.height;
                    if (area > bestArea) {
                        bestArea = area;
                        best = playerLayer;
                        CGRect contentRect = visible;
                        if (PSVHasVisibleRect(playerLayer.videoRect)) {
                            CGRect content = [layer convertRect:playerLayer.videoRect toLayer:rootLayer];
                            content = CGRectIntersection(content, visible);
                            if (PSVHasVisibleRect(content)) contentRect = content;
                        }
                        if (frameOut) *frameOut = contentRect;
                    }
                }
            }
        }

        // 不按固定节点数量截断：相册缓存页多时，会漏掉遍历顺序靠后的当前视频。
        // 使用迭代 + 指针去重，既避免递归爆栈，也避免重复访问。
        for (CALayer *sub in layer.sublayers) {
            PSVVideoScanEntry *child = [[PSVVideoScanEntry alloc] init];
            child.layer = sub;
            child.clipRect = clipRect;
            child.opacity = opacity;
            [stack addObject:child];
        }
    }
    return best;
}

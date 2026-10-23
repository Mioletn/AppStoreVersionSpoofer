/*
 * What the screen is made of, asked of the layer this engine renders into.
 *
 * A frame can be drawn, uploaded, swapped, and still never be seen: Core Animation shows nothing for a layer
 * that is not in a window, that is hidden, or whose drawable does not match the surface, and it reports none
 * of it -- the frame counter looks healthy while the screen is black. These answers are the difference
 * between a picture that never arrived and one that arrived into something nobody can see.
 */
#include <TargetConditionals.h>
#include <stddef.h>
#include <stdio.h>

#if TARGET_OS_IPHONE
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#endif

const char *husk_layer_describe(void *p, char *out, size_t n)
{
    if (!out || !n) return "";
#if TARGET_OS_IPHONE
    CALayer *l = (__bridge CALayer *)p;
    if (!l) { snprintf(out, n, "layer: none (the engine was given no surface)"); return out; }
    CGSize ds = CGSizeZero; int fbOnly = -1, pwt = -1, drawsAsync = -1;
    if ([l isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *m = (CAMetalLayer *)l;
        ds = m.drawableSize;
        fbOnly = m.framebufferOnly ? 1 : 0;
        pwt = m.presentsWithTransaction ? 1 : 0;
        drawsAsync = m.drawsAsynchronously ? 1 : 0;
    }
    UIWindow *win = l.window;
    snprintf(out, n,
             "layer %p: bounds %.0fx%.0f @%.0f,%.0f scale %.2f drawable %.0fx%.0f | hidden %d opacity %.2f "
             "opaque %d | fbOnly %d pwt %d async %d | superlayer %p window %p%s | inWindow %d",
             (void *)l, (double)l.bounds.size.width, (double)l.bounds.size.height,
             (double)l.bounds.origin.x, (double)l.bounds.origin.y, (double)l.contentsScale,
             (double)ds.width, (double)ds.height, (int)l.hidden, (double)l.opacity, (int)l.isOpaque,
             fbOnly, pwt, drawsAsync, (void *)l.superlayer, (void *)win,
             (win && win.hidden) ? " HIDDEN" : "", l.window != nil ? 1 : 0);
#else
    (void)p;
    snprintf(out, n, "layer: iOS only");
#endif
    return out;
}

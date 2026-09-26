//===---------------------------------------------------------------------------===//
/**
 * @file window_order.m
 * @brief Runtime check that no SketchyBar item window sits behind the bar.
 *
 * Reads the on-screen window list of the running GUI session, which
 * CGWindowList returns front to back. The widest SketchyBar window is taken as
 * the bar background; every item window that overlaps it and comes after it in
 * the list is covered. No UI events are sent.
 *
 * Run after clicking an application and then the bar, for a horizontal bar:
 *   clang -fobjc-arc -framework Foundation -framework CoreGraphics \
 *     window_order.m -o window-order && ./window-order
 *
 * Exit status: 0 when items are visible and none is covered, 1 when an item is
 * covered, 2 when the check is inconclusive.
 */
//===---------------------------------------------------------------------------===//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

/**
 * @brief Returns the bounds of a window list entry.
 *
 * @param window One entry of CGWindowListCopyWindowInfo().
 * @return The window bounds, or CGRectNull if they cannot be read.
 */
static CGRect window_bounds(NSDictionary *window) {
  CGRect bounds = CGRectNull;
  CGRectMakeWithDictionaryRepresentation(
      (__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds);
  return bounds;
}

int main(void) {
  @autoreleasepool {
    NSArray *windows = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));

    // Collect SketchyBar's windows and pick the widest one as the background.
    NSMutableArray *items = [NSMutableArray array];
    NSDictionary *background = nil;
    CGRect frame = CGRectZero;
    for (NSDictionary *window in windows) {
      if (![window[(id)kCGWindowOwnerName] isEqualToString:@"sketchybar"]) continue;
      [items addObject:window];
      CGRect bounds = window_bounds(window);
      if (bounds.size.width > frame.size.width) {
        background = window;
        frame = bounds;
      }
    }
    if (!background) {
      fprintf(stderr, "No visible SketchyBar background; check inconclusive.\n");
      return 2;
    }

    // Items listed after the background are behind it.
    bool behind = false;
    int visible = 0;
    int covered = 0;
    for (NSDictionary *window in items) {
      if (window == background) {
        behind = true;
        continue;
      }
      CGRect bounds = window_bounds(window);
      if (CGRectIsEmpty(bounds) || !CGRectIntersectsRect(frame, bounds)) continue;
      visible++;
      if (behind) covered++;
    }

    printf("Visible item windows: %d; covered by background: %d\n", visible, covered);
    return visible == 0 ? 2 : covered > 0;
  }
}

//===---------------------------------------------------------------------------===//

// Runtime smoke check for this horizontal bar; CGWindowList is front-to-back.
// Run after clicking an application and then the bar. No UI events are sent.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(void) {
  @autoreleasepool {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSMutableArray *items = [NSMutableArray array];
    NSDictionary *background = nil;
    CGRect frame = CGRectZero;
    for (NSDictionary *window in windows) {
      if (![window[(id)kCGWindowOwnerName] isEqualToString:@"sketchybar"]) continue;
      [items addObject:window];
      CGRect bounds;
      CGRectMakeWithDictionaryRepresentation(
          (__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds);
      if (bounds.size.width > frame.size.width) {
        background = window;
        frame = bounds;
      }
    }
    if (!background) {
      fprintf(stderr, "No visible SketchyBar background; check inconclusive.\n");
      return 2;
    }
    bool behind = false;
    int visible = 0, covered = 0;
    for (NSDictionary *window in items) {
      if (window == background) { behind = true; continue; }
      CGRect bounds;
      CGRectMakeWithDictionaryRepresentation(
          (__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds);
      if (CGRectIsEmpty(bounds) || !CGRectIntersectsRect(frame, bounds)) continue;
      visible++;
      if (behind) covered++;
    }
    printf("Visible item windows: %d; covered by background: %d\n", visible, covered);
    return visible == 0 ? 2 : covered > 0;
  }
}

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Empty geometry restores the source. Crop coordinates are decoded pixels;
// viewport and sample aspect ratio are used only for explicit crop-to-fill.
NSString *LCVideoCropGeometry(NSString *mode, CGSize source, CGSize viewport,
                            NSDictionary *detected, double sampleAspect, BOOL upright);

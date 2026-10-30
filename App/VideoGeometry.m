#import "VideoGeometry.h"
#import <math.h>

NSString *LCVideoCropGeometry(NSString *mode, CGSize source, CGSize viewport,
                            NSDictionary *detected, double sampleAspect, BOOL upright) {
    if ([mode isEqualToString:@"full"] || viewport.width <= 0 || viewport.height <= 0) return @"";
    BOOL fill = [mode isEqualToString:@"fill"];
    NSString *ratio = [NSString stringWithFormat:@"%ld:%ld", (long)llround(viewport.width*100), (long)llround(viewport.height*100)];
    if (!upright || source.width <= 0 || source.height <= 0) return fill ? ratio : @"";
    double x = [detected[@"x"] doubleValue], y = [detected[@"y"] doubleValue];
    double w = [detected[@"w"] doubleValue], h = [detected[@"h"] doubleValue];
    BOOL valid = isfinite(x) && isfinite(y) && isfinite(w) && isfinite(h) &&
        [detected[@"width"] doubleValue] == source.width && [detected[@"height"] doubleValue] == source.height &&
        x >= 0 && y >= 0 && w >= source.width*.15 && h >= source.height*.15 &&
        x+w <= source.width && y+h <= source.height;
    if (!valid) return fill ? ratio : @"";
    if (fill) {
        if (!isfinite(sampleAspect) || sampleAspect <= 0) return ratio;
        double target = viewport.width/viewport.height/sampleAspect;
        if (w/h > target) { double next = h*target; x += (w-next)/2; w = next; }
        else { double next = w/target; y += (h-next)/2; h = next; }
    }
    // Borders avoid ambiguous window offsets; round outwards to retain content.
    NSInteger left = floor(x), top = floor(y);
    NSInteger right = floor(source.width-x-w), bottom = floor(source.height-y-h);
    if (left+right+top+bottom == 0) return @"";
    return [NSString stringWithFormat:@"%ld+%ld+%ld+%ld", (long)left, (long)top, (long)right, (long)bottom];
}

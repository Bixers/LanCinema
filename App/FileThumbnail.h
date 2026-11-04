#import <UIKit/UIKit.h>

// Starts only when mounted in a window and cancels when its cell leaves it.
@interface LCFileThumbnail : UIView
- (instancetype)initWithSymbol:(NSString *)symbol color:(UIColor *)color large:(BOOL)large URL:(NSURL *)URL cacheKey:(NSString *)key;
@end

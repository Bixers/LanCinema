#import <UIKit/UIKit.h>

// Shared geometry keeps the detail header and landscape rows aligned.
FOUNDATION_EXPORT BOOL LCFileColumnsAreWide(CGFloat width, UITraitCollection *traits);
FOUNDATION_EXPORT UIView *LCFileEntry(NSDictionary *item, NSString *extra, BOOL icons, BOOL wide);
FOUNDATION_EXPORT UIStackView *LCFileColumns(NSArray<UIView *> *views, BOOL wide);

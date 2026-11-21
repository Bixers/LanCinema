#import <UIKit/UIKit.h>

// A device preference: independent of the connected computer/library.
BOOL LCAutomaticPlaybackLandscape(void);
void LCSetAutomaticPlaybackLandscape(BOOL enabled);
void LCRequestOrientation(UIViewController *controller, UIInterfaceOrientationMask mask);

@interface LCPortraitNavigationController : UINavigationController
@end

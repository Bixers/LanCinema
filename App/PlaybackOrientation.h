#import <UIKit/UIKit.h>

// A device preference: independent of the connected computer/library.
BOOL LCAutomaticPlaybackLandscape(void);
void LCSetAutomaticPlaybackLandscape(BOOL enabled);
void LCRequestOrientation(UIViewController *controller, UIInterfaceOrientationMask mask);
// Use uncropped display geometry, including pixel aspect and quarter turns.
UIInterfaceOrientationMask LCPlaybackOrientationMask(CGSize codedSize, double pixelAspect, BOOL transposed, BOOL automaticLandscape);

@interface LCPortraitNavigationController : UINavigationController
@end

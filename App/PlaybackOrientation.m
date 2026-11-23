#import "PlaybackOrientation.h"
#import <math.h>

UIInterfaceOrientationMask LCPlaybackOrientationMask(CGSize codedSize, double pixelAspect, BOOL transposed, BOOL automaticLandscape) {
    // Unknown dimensions stay upright instead of briefly rotating portrait media.
    if (!isfinite(codedSize.width) || !isfinite(codedSize.height) || codedSize.width <= 0 || codedSize.height <= 0)
        return UIInterfaceOrientationMaskPortrait;
    if (!isfinite(pixelAspect) || pixelAspect <= 0) pixelAspect = 1;
    double width = codedSize.width * pixelAspect, height = codedSize.height;
    if (!isfinite(width)) return UIInterfaceOrientationMaskPortrait;
    BOOL portrait = transposed ? width > height : height > width;
    if (portrait) return UIInterfaceOrientationMaskPortrait;
    return automaticLandscape ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAllButUpsideDown;
}

static NSString *const AutoLandscapeKey = @"automaticPlaybackLandscape";
BOOL LCAutomaticPlaybackLandscape(void) {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:AutoLandscapeKey];
    return saved ? [saved boolValue] : YES;
}
void LCSetAutomaticPlaybackLandscape(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:AutoLandscapeKey];
}
void LCRequestOrientation(UIViewController *controller, UIInterfaceOrientationMask mask) {
    UIWindowScene *scene = controller.viewIfLoaded.window.windowScene;
    if (!scene) return;
    [controller setNeedsUpdateOfSupportedInterfaceOrientations];
    [scene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask]
                                  errorHandler:^(NSError *error) {
        // UIKit may defer a request during a transition; masks still enforce
        // the policy. Never reopen playback or use private device rotation APIs.
    }];
}
@implementation LCPortraitNavigationController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationPortrait; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.presentedViewController) LCRequestOrientation(self, UIInterfaceOrientationMaskPortrait);
}
@end

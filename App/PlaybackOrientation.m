#import "PlaybackOrientation.h"

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

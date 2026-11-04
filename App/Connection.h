#import <UIKit/UIKit.h>
NSString *LCPassword(void);
BOOL LCStorePassword(NSString *password);
NSDictionary *LCParseQR(NSString *value);
NSString *LCQRCodeFromImage(UIImage *image);
NSURL *LCURLForHTTPQuery(NSURLComponents *components);

@interface ConnectionController : UIViewController
@property(nonatomic, copy) void (^onConnected)(void);
@end

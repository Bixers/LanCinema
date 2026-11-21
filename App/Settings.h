#import <UIKit/UIKit.h>

@interface LCSettingsController : UITableViewController
@property(nonatomic, copy) void (^onConnected)(void);
@end

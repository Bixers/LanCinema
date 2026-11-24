#import <UIKit/UIKit.h>

NSInteger LCAudioDelayMilliseconds(NSString *scope);
void LCSetAudioDelayMilliseconds(NSString *scope, NSInteger milliseconds);

@interface LCAudioTimingController : UITableViewController
@property(nonatomic, copy) NSString *scope;
@property(nonatomic, copy) void (^changed)(NSInteger milliseconds);
@end

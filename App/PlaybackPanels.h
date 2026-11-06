#import <UIKit/UIKit.h>

@interface LCHistoryController : UITableViewController
@property(nonatomic, copy) NSString *host;
@property(nonatomic, copy) NSString *library;
@property(nonatomic, copy) NSURL *(^urlForEndpoint)(NSString *, NSString *);
@property(nonatomic, copy) void (^openItem)(NSDictionary *);
@end

@interface LCDiagnosticsController : UIViewController
@property(nonatomic, copy) NSString *summary;
@property(nonatomic, copy) NSString *(^report)(void);
@property(nonatomic, copy) NSURL *mediaURL;
@property(nonatomic, copy) void (^retry)(void);
@end

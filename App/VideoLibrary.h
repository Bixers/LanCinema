#import <UIKit/UIKit.h>

NSArray<NSDictionary *> *LCFilterVideoItems(NSArray<NSDictionary *> *items, NSString *query);
@interface LCVideoShuffle : NSObject
- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items;
- (NSDictionary *)next;
@end

@interface LCVideoLibraryController : UITableViewController
@property(nonatomic, copy) NSString *host;
@property(nonatomic, copy) NSString *library;
@property(nonatomic, copy) NSURL *(^urlForEndpoint)(NSString *, NSString *);
@property(nonatomic, copy) void (^openItem)(NSDictionary *);
@property(nonatomic, copy) void (^openFolder)(NSString *);
@property(nonatomic, copy) void (^previewItems)(NSArray<NSDictionary *> *);
@end

#import <UIKit/UIKit.h>

@interface LCFavorites : NSObject
+ (instancetype)shared;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSArray<NSDictionary *> *)recordsForHost:(NSString *)host library:(NSString *)library;
- (BOOL)containsPath:(NSString *)path host:(NSString *)host library:(NSString *)library;
- (void)addItem:(NSDictionary *)item host:(NSString *)host library:(NSString *)library;
- (void)removePath:(NSString *)path host:(NSString *)host library:(NSString *)library;
@end

@interface LCFavoritesController : UITableViewController
@property(nonatomic, copy) NSString *host;
@property(nonatomic, copy) NSString *library;
@property(nonatomic, copy) NSURL *(^urlForEndpoint)(NSString *, NSString *);
@property(nonatomic, copy) void (^openItem)(NSDictionary *);
@end

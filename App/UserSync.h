#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSNotificationName const LCUserSyncChanged;
FOUNDATION_EXPORT NSArray<NSString *> *LCSyncedPreferenceKeys(void);

// Main-thread durable queue and merge logic; independent from network transport.
@interface LCUserSyncStore : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (void)queueKind:(NSString *)kind key:(NSString *)key value:(id)value host:(NSString *)host library:(NSString *)library;
- (NSDictionary *)requestForHost:(NSString *)host library:(NSString *)library;
- (BOOL)applyResponse:(NSDictionary *)response request:(NSDictionary *)request host:(NSString *)host library:(NSString *)library;
- (NSUInteger)pendingForHost:(NSString *)host library:(NSString *)library;
- (NSDate *)lastSyncForHost:(NSString *)host library:(NSString *)library;
@end

@interface LCUserSync : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) LCUserSyncStore *store;
@property(nonatomic, readonly) NSString *status;
- (void)connectHost:(NSString *)host library:(NSString *)library URL:(NSURL *)URL;
- (void)syncNow;
- (void)localChange;
- (NSString *)summary;
@end

FOUNDATION_EXPORT void LCQueueUserChange(NSUserDefaults *defaults, NSString *kind, NSString *key, id value, NSString *host, NSString *library);

@interface LCUserSyncController : UITableViewController
@end

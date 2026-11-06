#import <Foundation/Foundation.h>

NSString *LCProgressKey(NSString *host, NSString *library, NSString *path);

// Main-thread store. Records contain file metadata and confirmed rendered time,
// never connection credentials. Bounded across all connected libraries.
@interface LCPlaybackHistory : NSObject
+ (instancetype)shared;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSArray<NSDictionary *> *)recordsForHost:(NSString *)host library:(NSString *)library;
- (double)positionForItem:(NSDictionary *)item host:(NSString *)host library:(NSString *)library;
- (void)saveItem:(NSDictionary *)item host:(NSString *)host library:(NSString *)library position:(double)position duration:(double)duration;
- (void)removePath:(NSString *)path host:(NSString *)host library:(NSString *)library;
@end

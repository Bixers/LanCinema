#import "UserSync.h"

@interface LCUserSync ()
@property(nonatomic, strong) LCUserSyncStore *store;
@property(nonatomic, copy) NSString *status;
@property(nonatomic, copy) NSString *host;
@property(nonatomic, copy) NSString *library;
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSTimer *changeTimer;
@property(nonatomic, copy) NSDictionary *preferences;
@property(nonatomic) NSUInteger generation;
@end

@implementation LCUserSync
+ (instancetype)shared {
    static LCUserSync *sync; static dispatch_once_t once;
    dispatch_once(&once, ^{ sync = [LCUserSync new]; });
    return sync;
}
- (instancetype)init {
    if ((self = [super init])) {
        _store = [[LCUserSyncStore alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
        _status = @"连接电脑后自动同步";
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 15;
        configuration.timeoutIntervalForResource = 30;
        _session = [NSURLSession sessionWithConfiguration:configuration];
        _preferences = [self preferenceSnapshot];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultsChanged:) name:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        __weak typeof(self) weak = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) {
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [weak syncNow];
        }];
    }
    return self;
}
- (NSDictionary *)preferenceSnapshot {
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSString *key in LCSyncedPreferenceKeys()) {
        id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
        if (value) values[key] = value;
    }
    return values;
}
- (BOOL)contextIsCurrent {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return self.URL && [self.host isEqual:[defaults stringForKey:@"computerHost"]] && [self.library isEqual:[defaults stringForKey:@"libraryID"]];
}
- (void)defaultsChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *current = [self preferenceSnapshot];
        if ([self contextIsCurrent]) for (NSString *key in LCSyncedPreferenceKeys()) {
            if (current[key] == self.preferences[key] || [current[key] isEqual:self.preferences[key]]) continue;
            [self.store queueKind:@"preference" key:key value:current[key] host:self.host library:self.library];
            [self localChange];
        }
        self.preferences = current;
    });
}
- (void)foreground:(NSNotification *)note { [self syncNow]; }
- (void)background:(NSNotification *)note { [self syncNow]; }
- (void)announce:(BOOL)changed {
    [NSNotificationCenter.defaultCenter postNotificationName:LCUserSyncChanged object:self userInfo:@{@"recordsChanged":@(changed)}];
}
- (void)connectHost:(NSString *)host library:(NSString *)library URL:(NSURL *)URL {
    if (!host.length || !library.length || !URL) return;
    BOOL changed = ![self.host isEqual:host] || ![self.library isEqual:library] || ![self.URL isEqual:URL];
    if (changed) {
        ++self.generation; [self.task cancel]; self.task = nil;
        self.host = host; self.library = library; self.URL = URL;
        self.preferences = [self preferenceSnapshot];
    }
    [self syncNow];
}
- (void)localChange {
    [self.changeTimer invalidate];
    self.status = @"已保存到手机，等待同步";
    [self announce:NO];
    __weak typeof(self) weak = self;
    self.changeTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:NO block:^(NSTimer *t) { [weak syncNow]; }];
}
- (void)syncNow {
    if (self.task || ![self contextIsCurrent]) return;
    NSDictionary *payload = [self.store requestForHost:self.host library:self.library];
    NSError *encodingError;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&encodingError];
    if (!body || body.length > 2 * 1024 * 1024) {
        self.status = @"记录暂时无法发送，手机副本仍保留"; [self announce:NO]; return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.URL];
    request.HTTPMethod = @"POST"; request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
#if DEBUG
    NSString *scope = [NSUserDefaults.standardUserDefaults stringForKey:@"uiTestSyncScope"];
    if (scope) [request setValue:scope forHTTPHeaderField:@"X-LC-Test-Scope"];
#endif
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSString *host = self.host, *library = self.library;
    NSUInteger generation = self.generation;
    self.status = @"正在同步…"; [self announce:NO];
    __weak typeof(self) weak = self;
    self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        dispatch_async(dispatch_get_main_queue(), ^{
            LCUserSync *s = weak;
            if (!s || generation != s.generation) return;
            s.task = nil;
            if (![s contextIsCurrent]) return;
            BOOL success = !error && code == 200 && [s.store applyResponse:json request:payload host:host library:library];
            s.preferences = [s preferenceSnapshot];
            if (success) {
                BOOL conflicts = [json[@"conflicts"] isKindOfClass:NSArray.class] && [json[@"conflicts"] count] > 0;
                s.status = conflicts ? @"同步完成；冲突项保留电脑已确认的记录" : @"已同步到电脑";
                [s announce:YES];
                if ([s.store pendingForHost:host library:library]) [s syncNow];
            } else {
                BOOL identityChanged = [json isKindOfClass:NSDictionary.class] && [json[@"identityChanged"] boolValue];
                s.status = identityChanged ? @"电脑身份发生变化，已暂停同步并保留手机记录" :
                    (code == 404 || code == 501 ? @"电脑端不支持同步，请更新电脑端" :
                     (code == 401 ? @"同步密码失效，请重新连接电脑" : @"同步未完成，记录保留在手机；稍后自动重试"));
                [s announce:NO];
            }
        });
    }];
    [self.task resume];
}
- (NSString *)summary {
    if (!self.host.length) return @"请先返回文件库连接电脑。";
    NSDate *date = [self.store lastSyncForHost:self.host library:self.library];
    NSString *last = date ? [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle] : @"尚未成功同步";
    return [NSString stringWithFormat:@"%@\n待同步：%lu 项\n最近成功：%@", self.status, (unsigned long)[self.store pendingForHost:self.host library:self.library], last];
}
@end

void LCQueueUserChange(NSUserDefaults *defaults, NSString *kind, NSString *key, id value, NSString *host, NSString *library) {
    // Suite-based stores used by tests must not touch production data or network.
    if (defaults != NSUserDefaults.standardUserDefaults) return;
    LCUserSync *sync = LCUserSync.shared;
    [sync.store queueKind:kind key:key value:value host:host library:library];
    [sync localChange];
}

@implementation LCUserSyncController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"数据同步";
    self.tableView.accessibilityIdentifier = @"userSyncList";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh:) name:LCUserSyncChanged object:nil];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
    [self.tableView reloadData];
}
- (void)refresh:(NSNotification *)note { [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 1 ? 2 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"此电脑和共享目录", @"备份与同步", @"升级前保护记录"][section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.textProperties.numberOfLines = 0;
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    if (path.section == 0) {
        content.text = LCUserSync.shared.summary;
        cell.accessibilityIdentifier = @"userSyncStatus";
    } else if (path.section == 1) {
        content.text = path.row == 0 ? @"立即同步" : @"导出手机记录备份…";
        content.image = [UIImage systemImageNamed:path.row == 0 ? @"arrow.triangle.2.circlepath" : @"square.and.arrow.up"];
        content.textProperties.color = self.view.tintColor;
        cell.accessibilityIdentifier = path.row == 0 ? @"syncNow" : @"exportUserBackup";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        content.text = @"收藏、观看进度和播放／浏览偏好在手机与电脑各保存一份。断网时先存手机，重连后自动同步。\n\n升级前先确认「已同步到电脑」，并保留导出的备份。首次升级旧版时，需先通过 iPhone 的电脑备份提取旧记录；旧版无法直接上传。\n\n覆盖安装须保持原 App 标识，不要先卸载。连接密码不参与同步。";
    }
    cell.contentConfiguration = content;
    cell.selectionStyle = path.section == 1 ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section != 1) return;
    if (path.row == 0) { [LCUserSync.shared syncNow]; return; }
    NSMutableDictionary *prefs = [NSMutableDictionary new];
    NSDictionary *all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    for (NSString *key in all) if ([key isEqual:@"favoritesV1"] || [key isEqual:@"playbackHistoryV1"] || [key hasPrefix:@"progress:"] || [LCSyncedPreferenceKeys() containsObject:key]) prefs[key] = all[key];
    NSDictionary *archive = @{@"format":@"LanCinema-legacy-backup", @"version":@1, @"domain":[@"AppDomain-" stringByAppendingString:NSBundle.mainBundle.bundleIdentifier], @"exportedAt":@(NSDate.date.timeIntervalSince1970), @"preferences":prefs};
    NSError *error;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:archive format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    NSURL *URL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"LanCinema-records-%@.plist", NSUUID.UUID.UUIDString]]];
    if (!data || ![data writeToURL:URL options:NSDataWritingAtomic error:&error]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未能导出备份" message:@"手机记录仍保留，请检查可用空间后重试。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil]; return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[URL] applicationActivities:nil];
    share.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:path];
    [self presentViewController:share animated:YES completion:nil];
}
@end

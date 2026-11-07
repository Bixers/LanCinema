#import "Favorites.h"
#import "FilePresentation.h"

static NSString *const FavoritesKey = @"favoritesV1";
@interface LCFavorites ()
@property(nonatomic, strong) NSUserDefaults *defaults;
@end
@implementation LCFavorites
+ (instancetype)shared {
    static LCFavorites *store; static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; });
    return store;
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}
- (NSArray<NSDictionary *> *)allRecords {
    NSMutableArray *valid = [NSMutableArray new];
    for (id r in [self.defaults arrayForKey:FavoritesKey]) {
        if (![r isKindOfClass:NSDictionary.class] || ![r[@"host"] isKindOfClass:NSString.class] ||
            ![r[@"library"] isKindOfClass:NSString.class] || ![r[@"item"] isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *item = r[@"item"];
        if (![item[@"path"] isKindOfClass:NSString.class] || ![item[@"path"] length] ||
            ![item[@"name"] isKindOfClass:NSString.class] ||
            ![item[@"directory"] isKindOfClass:NSNumber.class] || ![item[@"video"] isKindOfClass:NSNumber.class]) continue;
        if ([item[@"directory"] boolValue] || [item[@"video"] boolValue]) [valid addObject:r];
    }
    return valid;
}
- (BOOL)record:(NSDictionary *)r matchesHost:(NSString *)host library:(NSString *)library {
    return [r[@"host"] isEqual:host ?: @""] && [r[@"library"] isEqual:library ?: @""];
}
- (NSArray<NSDictionary *> *)recordsForHost:(NSString *)host library:(NSString *)library {
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *r in [self allRecords]) if ([self record:r matchesHost:host library:library]) [result addObject:r];
    return result;
}
- (BOOL)containsPath:(NSString *)path host:(NSString *)host library:(NSString *)library {
    for (NSDictionary *r in [self recordsForHost:host library:library]) if ([r[@"item"][@"path"] isEqual:path]) return YES;
    return NO;
}
- (void)removePath:(NSString *)path host:(NSString *)host library:(NSString *)library {
    NSMutableArray *records = [[self allRecords] mutableCopy];
    NSIndexSet *matches = [records indexesOfObjectsPassingTest:^BOOL(NSDictionary *r, NSUInteger i, BOOL *stop) {
        return [self record:r matchesHost:host library:library] && [r[@"item"][@"path"] isEqual:path];
    }];
    [records removeObjectsAtIndexes:matches];
    [self.defaults setObject:records forKey:FavoritesKey];
}
- (void)addItem:(NSDictionary *)item host:(NSString *)host library:(NSString *)library {
    if (![item[@"path"] isKindOfClass:NSString.class] || ![item[@"path"] length] ||
        !([item[@"directory"] boolValue] || [item[@"video"] boolValue]) || !host.length || !library.length) return;
    // Repeated Add is idempotent; it must not reorder or duplicate a saved item.
    if ([self containsPath:item[@"path"] host:host library:library]) return;
    NSMutableDictionary *metadata = [NSMutableDictionary new];
    for (NSString *key in @[@"path", @"name", @"size", @"modified", @"thumbnailVersion"]) {
        id value = item[key];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) metadata[key] = value;
    }
    metadata[@"name"] = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : [item[@"path"] lastPathComponent];
    metadata[@"directory"] = @([item[@"directory"] boolValue]);
    metadata[@"video"] = @([item[@"video"] boolValue]);
    NSMutableArray *records = [[self allRecords] mutableCopy];
    [records insertObject:@{@"host":host, @"library":library, @"item":metadata} atIndex:0];
    [self.defaults setObject:records forKey:FavoritesKey];
}
@end

@interface LCFavoritesController ()
@property(nonatomic, copy) NSArray<NSDictionary *> *records;
@property(nonatomic, strong) UILabel *empty;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic) NSInteger generation;
@end
@implementation LCFavoritesController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"收藏";
    self.tableView.accessibilityIdentifier = @"favoritesList";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 110;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionFooterHeight = 70;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"编辑" style:UIBarButtonItemStylePlain target:self action:@selector(toggleEditing)];
    self.empty = [UILabel new]; self.empty.numberOfLines = 0;
    self.empty.text = @"还没有收藏\n\n在文件库中长按视频或文件夹\n选择「加入收藏」，下次更快找到";
    self.empty.textColor = UIColor.labelColor;
    self.empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.empty.adjustsFontForContentSizeCategory = YES;
    self.empty.textAlignment = NSTextAlignmentCenter;
    // A scrollable background keeps the complete instruction reachable in landscape at XXXL.
    UIScrollView *background = [UIScrollView new];
    self.empty.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:self.empty];
    NSLayoutConstraint *center = [self.empty.centerYAnchor constraintEqualToAnchor:background.frameLayoutGuide.centerYAnchor];
    center.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [self.empty.leadingAnchor constraintEqualToAnchor:background.contentLayoutGuide.leadingAnchor constant:24],
        [self.empty.trailingAnchor constraintEqualToAnchor:background.contentLayoutGuide.trailingAnchor constant:-24],
        [self.empty.widthAnchor constraintEqualToAnchor:background.frameLayoutGuide.widthAnchor constant:-48],
        [self.empty.topAnchor constraintGreaterThanOrEqualToAnchor:background.contentLayoutGuide.topAnchor constant:24],
        [self.empty.bottomAnchor constraintEqualToAnchor:background.contentLayoutGuide.bottomAnchor constant:-24], center]];
    self.tableView.backgroundView = background;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
    [self reloadFavorites];
}
- (void)reloadFavorites {
    self.records = [LCFavorites.shared recordsForHost:self.host library:self.library];
    self.tableView.backgroundView.hidden = self.records.count > 0;
    self.navigationItem.rightBarButtonItem.enabled = self.records.count > 0;
    if (!self.records.count) [self setEditing:NO animated:NO];
    [self.tableView reloadData];
}
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    self.navigationItem.rightBarButtonItem.title = editing ? @"完成" : @"编辑";
}
- (void)toggleEditing { [self setEditing:!self.editing animated:YES]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.records.count; }
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (!self.records.count) return nil;
    UITableViewHeaderFooterView *footer = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:nil];
    UIListContentConfiguration *content = [UIListContentConfiguration plainFooterConfiguration];
    content.text = @"最近收藏在前 · 仅此电脑和共享目录\n左滑取消收藏，不会删除原文件。";
    content.textProperties.numberOfLines = 0;
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    content.textProperties.color = UIColor.labelColor;
    footer.contentConfiguration = content;
    return footer;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"favorite"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"favorite"];
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
    NSDictionary *item = self.records[indexPath.row][@"item"];
    NSString *parent = [item[@"path"] stringByDeletingLastPathComponent];
    UIView *entry = LCFileEntry(item, [@"位置：" stringByAppendingString:parent.length ? parent : @"共享文件夹"], NO, NO,
                                self.traitCollection, self.urlForEndpoint(@"/api/thumbnail", item[@"path"]), self.library);
    entry.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:entry];
    [NSLayoutConstraint activateConstraints:@[
        [entry.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [entry.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [entry.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [entry.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12]]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)cancelCheck { ++self.generation; [self.task cancel]; self.task = nil; self.title = @"收藏"; }
- (void)removeItem:(NSDictionary *)item {
    [self cancelCheck];
    [LCFavorites.shared removePath:item[@"path"] host:self.host library:self.library];
    [self reloadFavorites];
}
- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath { return @"取消收藏"; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style == UITableViewCellEditingStyleDelete) [self removeItem:self.records[indexPath.row][@"item"]];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self cancelCheck];
    NSInteger generation = self.generation;
    NSDictionary *saved = self.records[indexPath.row][@"item"];
    self.title = @"正在检查收藏…";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.urlForEndpoint(@"/api/list", [saved[@"path"] stringByDeletingLastPathComponent])];
    request.timeoutInterval = 12; request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) owner = self;
    self.task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            LCFavoritesController *s = owner;
            if (!s || generation != s.generation || !s.task || error.code == NSURLErrorCancelled) return;
            s.task = nil; s.title = @"收藏";
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            BOOL valid = status == 200 && [json isKindOfClass:NSDictionary.class] && [json[@"items"] isKindOfClass:NSArray.class];
            NSDictionary *found = nil;
            if (valid && [json[@"libraryID"] isEqual:s.library]) {
                for (id item in json[@"items"]) {
                    if ([item isKindOfClass:NSDictionary.class] && [item[@"path"] isEqual:saved[@"path"]] &&
                        [item[@"directory"] boolValue] == [saved[@"directory"] boolValue] &&
                        ([item[@"directory"] boolValue] || [item[@"video"] boolValue])) { found = item; break; }
                }
            }
            if (found) { if (s.openItem) s.openItem(found); return; }
            BOOL missing = status == 404 || valid;
            NSString *message = missing ? @"文件或文件夹已被移动、删除，或共享目录已改变。可返回文件库重新查找。" :
                (status == 401 ? @"连接密码已改变，请返回文件库修改电脑连接设置。收藏已保留。" : @"暂时无法读取电脑文件，请检查 Wi-Fi 和电脑端服务后重试。收藏已保留。");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂时无法打开收藏" message:message preferredStyle:UIAlertControllerStyleAlert];
            if (missing) [alert addAction:[UIAlertAction actionWithTitle:@"取消收藏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [s removeItem:saved]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
            [s presentViewController:alert animated:YES completion:nil];
        });
    }];
    [self.task resume];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self cancelCheck]; }
- (void)dealloc { [self.task cancel]; }
@end

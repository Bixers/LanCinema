#import "VideoLibrary.h"
#import "FilePresentation.h"
#import "Favorites.h"
#import "PlaybackHistory.h"
#import "Connection.h"

NSArray<NSDictionary *> *LCFilterVideoItems(NSArray<NSDictionary *> *items, NSString *query) {
    NSArray *words = [[query precomposedStringWithCompatibilityMapping] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
        NSString *path = [item[@"path"] precomposedStringWithCompatibilityMapping];
        for (NSString *word in words) if (word.length && [path rangeOfString:word options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) return NO;
        return YES;
    }]];
}

@interface LCVideoShuffle ()
@property(nonatomic, copy) NSArray *items;
@property(nonatomic, strong) NSMutableArray *remaining;
@property(nonatomic, copy) NSString *lastPath;
@end
@implementation LCVideoShuffle
- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items {
    if ((self = [super init])) { _items = [items copy]; _remaining = [NSMutableArray new]; }
    return self;
}
- (NSDictionary *)next {
    if (!self.items.count) return nil;
    if (!self.remaining.count) {
        self.remaining = [self.items mutableCopy];
        for (NSUInteger count = self.remaining.count; count > 1; count--)
            [self.remaining exchangeObjectAtIndex:count-1 withObjectAtIndex:arc4random_uniform((uint32_t)count)];
        if (self.remaining.count > 1 && [self.remaining.lastObject[@"path"] isEqual:self.lastPath])
            [self.remaining exchangeObjectAtIndex:0 withObjectAtIndex:self.remaining.count-1];
    }
    NSDictionary *item = self.remaining.lastObject;
    [self.remaining removeLastObject]; self.lastPath = item[@"path"];
    return item;
}
@end

@interface LCVideoLibraryController () <UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic, copy) NSArray *items;
@property(nonatomic, copy) NSArray *visible;
@property(nonatomic, strong) NSDictionary *progress;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, strong) UIBarButtonItem *randomButton;
@property(nonatomic) NSInteger generation;
@property(nonatomic) BOOL active;
@property(nonatomic) NSInteger skipped;
@end
@implementation LCVideoLibraryController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"全部视频"; self.items = @[]; self.visible = @[];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 330;
    self.tableView.accessibilityIdentifier = @"allVideosList";
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self; search.searchBar.delegate = self; search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"名称或路径，空格分隔关键词";
    self.navigationItem.searchController = search; self.navigationItem.hidesSearchBarWhenScrolling = NO; self.definesPresentationContext = YES;
    self.randomButton = [[UIBarButtonItem alloc] initWithTitle:@"随机试看" style:UIBarButtonItemStylePlain target:self action:@selector(randomPreview)];
    self.randomButton.accessibilityIdentifier = @"randomPreview";
    UIBarButtonItem *recent = [[UIBarButtonItem alloc] initWithTitle:@"搜索历史" style:UIBarButtonItemStylePlain target:self action:@selector(showSearchHistory)];
    self.toolbarItems = @[[UIBarButtonItem flexibleSpaceItem], self.randomButton, [UIBarButtonItem flexibleSpaceItem], recent, [UIBarButtonItem flexibleSpaceItem]];
    [self configureSort];
    self.message = [UILabel new]; self.message.numberOfLines = 0; self.message.textAlignment = NSTextAlignmentCenter;
    self.message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.message.adjustsFontForContentSizeCategory = YES;
    self.message.textColor = UIColor.secondaryLabelColor; self.message.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *background = [UIView new]; [background addSubview:self.message];
    [NSLayoutConstraint activateConstraints:@[[self.message.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:24],
        [self.message.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-24], [self.message.centerYAnchor constraintEqualToAnchor:background.centerYAnchor]]];
    self.tableView.backgroundView = background;
    self.refreshControl = [UIRefreshControl new]; [self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; self.active = YES; [self.navigationController setToolbarHidden:NO animated:animated];
    NSMutableDictionary *progress = [NSMutableDictionary new];
    for (NSDictionary *record in [LCPlaybackHistory.shared recordsForHost:self.host library:self.library]) progress[record[@"item"][@"path"]] = record;
    self.progress = progress;
    if (!self.items.count) [self load:NO]; else [self filter];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.active = NO; ++self.generation; [self.task cancel]; self.task = nil; [self.refreshControl endRefreshing]; }
- (void)refresh { [self load:YES]; }
- (void)load:(BOOL)refresh {
    [self.task cancel]; NSInteger generation = ++self.generation;
    NSURL *url = self.urlForEndpoint(@"/api/library", nil);
    if (refresh) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        c.queryItems = [c.queryItems arrayByAddingObject:[NSURLQueryItem queryItemWithName:@"refresh" value:@"1"]]; url = LCURLForHTTPQuery(c);
    }
    if (!url) { self.message.text = @"请返回文件库连接电脑"; [self.refreshControl endRefreshing]; return; }
    if (!self.items.count) self.message.text = @"正在汇总所有共享文件夹…\n首次读取可能需要稍候";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url]; request.timeoutInterval = 20; request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) owner = self;
    self.task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            LCVideoLibraryController *s = owner;
            if (!s || !s.active || generation != s.generation) return;
            s.task = nil;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (status == 200 && [json isKindOfClass:NSDictionary.class] && [json[@"libraryID"] isEqual:s.library]) {
                if ([json[@"state"] isEqual:@"ready"] && [json[@"items"] isKindOfClass:NSArray.class]) {
                    NSMutableArray *valid = [NSMutableArray new];
                    for (id item in json[@"items"]) if ([item isKindOfClass:NSDictionary.class] && [item[@"path"] isKindOfClass:NSString.class] && [item[@"name"] isKindOfClass:NSString.class] && [item[@"video"] boolValue]) [valid addObject:item];
                    s.items = valid; s.skipped = [json[@"skipped"] integerValue]; [s filter];
                }
                if ([json[@"state"] isEqual:@"preparing"] || [json[@"refreshing"] boolValue]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (s.active && generation == s.generation) [s load:NO]; }); return;
                }
            } else {
                s.message.text = status == 404 ? @"请更新电脑端后下拉重试" : (status == 401 ? @"密码已改变，请返回设置重新连接" : @"无法读取视频库\n请检查电脑连接，返回文件库刷新后重试");
                if (s.items.count) { s.navigationItem.prompt = @"刷新失败，显示上次结果；下拉重试"; }
            }
            [s.refreshControl endRefreshing];
        });
    }]; [self.task resume];
}
- (void)configureSort {
    NSMutableArray *actions = [NSMutableArray new]; NSArray *fields = @[@"name", @"size", @"modified"];
    NSString *selected = [NSUserDefaults.standardUserDefaults stringForKey:@"allVideoSort"] ?: @"name";
    NSArray *titles = @[@"文件名", @"大小：从大到小", @"修改时间：从新到旧"];
    __weak typeof(self) owner = self;
    for (NSUInteger i=0;i<fields.count;i++) {
        NSString *field = fields[i]; UIAction *action = [UIAction actionWithTitle:titles[i] image:nil identifier:nil handler:^(UIAction *a) {
            [NSUserDefaults.standardUserDefaults setObject:field forKey:@"allVideoSort"]; [owner configureSort]; [owner filter];
        }]; action.state = [selected isEqual:field] ? UIMenuElementStateOn : UIMenuElementStateOff; [actions addObject:action];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] menu:[UIMenu menuWithChildren:actions]];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"视频库排序";
}
- (void)filter {
    NSString *query = self.navigationItem.searchController.searchBar.text ?: @"";
    NSString *field = [NSUserDefaults.standardUserDefaults stringForKey:@"allVideoSort"] ?: @"name";
    if (![@[@"name", @"size", @"modified"] containsObject:field]) field = @"name";
    NSSortDescriptor *primary = [field isEqual:@"name"] ? [NSSortDescriptor sortDescriptorWithKey:field ascending:YES selector:@selector(localizedStandardCompare:)] : [NSSortDescriptor sortDescriptorWithKey:field ascending:NO];
    self.visible = [LCFilterVideoItems(self.items, query) sortedArrayUsingDescriptors:@[primary, [NSSortDescriptor sortDescriptorWithKey:@"path" ascending:YES]]];
    self.navigationItem.prompt = [NSString stringWithFormat:@"%lu 部视频%@", (unsigned long)self.visible.count, self.skipped ? @" · 部分目录无法读取" : @""];
    self.message.text = self.visible.count ? @"" : (self.items.count ? @"没有匹配的视频\n试试减少关键词" : @"共享目录中没有可读取的视频\n添加文件后下拉刷新");
    self.randomButton.enabled = self.visible.count > 0; [self.tableView reloadData];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)search { [self filter]; }
- (NSString *)searchHistoryKey { return [NSString stringWithFormat:@"videoSearchHistory:%@:%@", self.host, self.library]; }
- (void)saveQuery {
    NSString *query = [self.navigationItem.searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length || query.length > 200) return;
    NSMutableArray *history = [([NSUserDefaults.standardUserDefaults arrayForKey:self.searchHistoryKey] ?: @[]) mutableCopy];
    [history removeObject:query]; [history insertObject:query atIndex:0];
    while (history.count > 10) [history removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:history forKey:self.searchHistoryKey];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [self saveQuery]; [searchBar resignFirstResponder]; }
- (void)showSearchHistory {
    NSArray *history = [NSUserDefaults.standardUserDefaults arrayForKey:self.searchHistoryKey] ?: @[];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"搜索历史" message:history.count ? @"保存在此手机，可随时清空" : @"搜索后按键盘「搜索」或打开结果，即可记住关键词" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) owner = self;
    for (NSString *query in history) if ([query isKindOfClass:NSString.class]) [sheet addAction:[UIAlertAction actionWithTitle:query style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { owner.navigationItem.searchController.searchBar.text = query; [owner filter]; }]];
    if (history.count) [sheet addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [NSUserDefaults.standardUserDefaults removeObjectForKey:owner.searchHistoryKey]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)randomPreview { [self saveQuery]; [self.navigationItem.searchController.searchBar resignFirstResponder]; if (self.visible.count && self.previewItems) self.previewItems(self.visible); }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.visible.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"allVideo"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"allVideo"];
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
    NSDictionary *item = self.visible[indexPath.row], *record = self.progress[item[@"path"]];
    NSString *extra = [@"位置：" stringByAppendingString:[item[@"path"] stringByDeletingLastPathComponent]];
    if (record) extra = [NSString stringWithFormat:@"已看 %.0f / %.0f 分钟\n%@", [record[@"position"] doubleValue]/60, [record[@"duration"] doubleValue]/60, extra];
    UIView *entry = LCFileEntry(item, extra, YES, NO, self.traitCollection, self.urlForEndpoint(@"/api/thumbnail", item[@"path"]), self.library);
    entry.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:entry];
    [NSLayoutConstraint activateConstraints:@[[entry.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor], [entry.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [entry.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12], [entry.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-16]]];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { [tableView deselectRowAtIndexPath:indexPath animated:YES]; [self saveQuery]; if (self.openItem) self.openItem(self.visible[indexPath.row]); }
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSDictionary *item = self.visible[indexPath.row]; __weak typeof(self) owner = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        LCVideoLibraryController *s = owner; BOOL favorite = [LCFavorites.shared containsPath:item[@"path"] host:s.host library:s.library];
        UIAction *folder = [UIAction actionWithTitle:@"打开所在文件夹" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) { if (s.openFolder) s.openFolder([item[@"path"] stringByDeletingLastPathComponent]); }];
        UIAction *star = [UIAction actionWithTitle:favorite ? @"取消收藏" : @"加入收藏" image:[UIImage systemImageNamed:@"star"] identifier:nil handler:^(UIAction *a) {
            if (favorite) [LCFavorites.shared removePath:item[@"path"] host:s.host library:s.library]; else [LCFavorites.shared addItem:item host:s.host library:s.library];
        }]; return [UIMenu menuWithChildren:@[folder, star]];
    }];
}
- (void)dealloc { [self.task cancel]; }
@end

#import "PlaybackPanels.h"
#import "PlaybackHistory.h"
#import "FilePresentation.h"

static NSString *HistoryTime(double seconds) {
    NSInteger s = MAX(0, (NSInteger)seconds);
    return s >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)s/3600, (long)(s/60)%60, (long)s%60] : [NSString stringWithFormat:@"%02ld:%02ld", (long)s/60, (long)s%60];
}
@interface LCHistoryController ()
@property(nonatomic, copy) NSArray *records;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) UILabel *empty;
@property(nonatomic) NSInteger requestGeneration;
@end
@implementation LCHistoryController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"继续观看";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 120;
    self.tableView.accessibilityIdentifier = @"continueWatchingList";
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    self.editButtonItem.title = @"编辑";
    self.empty = [UILabel new]; self.empty.numberOfLines = 0;
    self.empty.textAlignment = NSTextAlignmentCenter;
    self.empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.empty.adjustsFontForContentSizeCategory = YES;
    self.empty.textColor = UIColor.secondaryLabelColor;
    self.empty.text = @"还没有未看完的视频\n\n播放后会自动记住位置\n返回文件库选择一个视频";
    self.empty.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *background = [UIView new]; [background addSubview:self.empty];
    [NSLayoutConstraint activateConstraints:@[
        [self.empty.leadingAnchor constraintEqualToAnchor:background.safeAreaLayoutGuide.leadingAnchor constant:24],
        [self.empty.trailingAnchor constraintEqualToAnchor:background.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [self.empty.centerYAnchor constraintEqualToAnchor:background.centerYAnchor]]];
    self.tableView.backgroundView = background;
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.navigationController setToolbarHidden:YES animated:animated]; [self reloadHistory]; }
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated]; self.editButtonItem.title = editing ? @"完成" : @"编辑";
}
- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath { return @"移除记录"; }
- (void)reloadHistory {
    self.records = [LCPlaybackHistory.shared recordsForHost:self.host library:self.library];
    self.empty.hidden = self.records.count > 0;
    self.navigationItem.rightBarButtonItem.enabled = self.records.count > 0;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.records.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.records.count ? @"按最近观看排序 · 仅此电脑和共享目录\n左滑移除记录，不会删除视频。" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"history"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"history"];
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
    NSDictionary *r = self.records[indexPath.row], *item = r[@"item"];
    NSString *progress = [NSString stringWithFormat:@"继续 %@%@", HistoryTime([r[@"position"] doubleValue]), [r[@"duration"] doubleValue] > 0 ? [@" / " stringByAppendingString:HistoryTime([r[@"duration"] doubleValue])] : @""];
    NSString *date = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[r[@"updated"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
    NSString *parent = [item[@"path"] stringByDeletingLastPathComponent];
    NSString *extra = [NSString stringWithFormat:@"%@\n%@\n位置：%@", progress, date, parent.length ? parent : @"共享文件夹"];
    UIView *entry = LCFileEntry(item, extra, NO, NO, self.traitCollection, self.urlForEndpoint(@"/api/thumbnail", item[@"path"]), self.library);
    entry.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:entry];
    [NSLayoutConstraint activateConstraints:@[
        [entry.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [entry.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [entry.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [entry.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12]]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    ++self.requestGeneration;
    [self.task cancel]; self.task = nil; self.title = @"继续观看";
    [LCPlaybackHistory.shared removePath:self.records[indexPath.row][@"item"][@"path"] host:self.host library:self.library];
    [self reloadHistory];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.task) return;
    NSInteger generation = ++self.requestGeneration;
    NSDictionary *saved = self.records[indexPath.row][@"item"];
    self.title = @"正在检查文件…";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.urlForEndpoint(@"/api/list", [saved[@"path"] stringByDeletingLastPathComponent])];
    request.timeoutInterval = 12; request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) owner = self;
    self.task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            LCHistoryController *s = owner; if (!s || generation != s.requestGeneration || !s.task || error.code == NSURLErrorCancelled) return;
            s.task = nil; s.title = @"继续观看";
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            NSDictionary *found = nil;
            if (status == 200 && [json isKindOfClass:NSDictionary.class] && [json[@"items"] isKindOfClass:NSArray.class] && [json[@"libraryID"] isEqual:s.library])
                for (NSDictionary *item in json[@"items"]) if ([item[@"path"] isEqual:saved[@"path"]] && [item[@"video"] boolValue]) { found = item; break; }
            if (found) { if (s.openItem) s.openItem(found); return; }
            BOOL missing = status == 404 || status == 200;
            NSString *message = missing ? @"文件已被移动、删除，或共享目录已改变。可返回文件库重新查找。" : (status == 401 ? @"连接密码已改变，请返回文件库修改电脑连接设置。" : @"暂时无法连接电脑，请检查 Wi-Fi 和电脑端服务后重试。观看记录已保留。");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂时无法继续播放" message:message preferredStyle:UIAlertControllerStyleAlert];
            if (missing) [alert addAction:[UIAlertAction actionWithTitle:@"移除记录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
                [LCPlaybackHistory.shared removePath:saved[@"path"] host:s.host library:s.library]; [s reloadHistory];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
            [s presentViewController:alert animated:YES completion:nil];
        });
    }];
    [self.task resume];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController) { ++self.requestGeneration; [self.task cancel]; self.task = nil; }
}
- (void)dealloc { [self.task cancel]; }
@end

@interface LCDiagnosticsController ()
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, copy) NSString *connectionResult;
@property(nonatomic, strong) UIBarButtonItem *checkButton;
@end
@implementation LCDiagnosticsController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"播放诊断";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(exportReport)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"导出诊断";
    self.checkButton = [[UIBarButtonItem alloc] initWithTitle:@"检查连接" style:UIBarButtonItemStylePlain target:self action:@selector(checkConnection)];
    self.toolbarItems = @[self.checkButton, [UIBarButtonItem flexibleSpaceItem], [[UIBarButtonItem alloc] initWithTitle:@"重新打开视频" style:UIBarButtonItemStylePlain target:self action:@selector(retryPlayback)]];
    [self.navigationController setToolbarHidden:NO];
    self.textView = [UITextView new]; self.textView.editable = NO;
    self.textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.textView.adjustsFontForContentSizeCategory = YES;
    self.textView.textColor = UIColor.labelColor;
    self.textView.backgroundColor = UIColor.systemBackgroundColor;
    self.textView.textContainerInset = UIEdgeInsetsMake(20, 16, 24, 16);
    self.textView.accessibilityIdentifier = @"diagnosticReport";
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];
    [self refreshText];
}
- (void)refreshText {
    self.textView.text = [NSString stringWithFormat:@"%@\n\n%@\n\n报告仅含本次播放的状态、时间与帧数，不包含密码、地址或文件名称。\n\n%@", self.summary ?: @"", self.connectionResult ?: @"遇到加载或拖动问题时，可先检查连接；仍无法恢复时重新打开视频。", self.report ? self.report() : @""];
}
- (void)checkConnection {
    if (self.task || !self.mediaURL) return;
    self.checkButton.enabled = NO; self.connectionResult = @"正在检查电脑连接与进度读取…"; [self refreshText];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.mediaURL];
    request.HTTPMethod = @"HEAD"; [request setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
    request.timeoutInterval = 8; request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) owner = self;
    self.task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LCDiagnosticsController *s = owner; if (!s || error.code == NSURLErrorCancelled) return;
            s.task = nil; s.checkButton.enabled = YES;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            NSString *message = status == 206 ? @"电脑连接正常，支持按位置读取。若仍卡住，请尝试重新打开视频。" : (status == 401 ? @"密码已失效，请返回文件库重新连接电脑。" : (status == 404 ? @"文件或播放缓存不可用，请返回文件库刷新后重新打开。" : (error ? @"无法连接电脑，请检查同一 Wi-Fi、电脑休眠和文件服务。" : @"电脑已响应，但未确认按位置读取支持。")));
            s.connectionResult = [NSString stringWithFormat:@"%@\nHTTP %ld · 网络错误 %ld", message, (long)status, (long)error.code];
            [s refreshText];
        });
    }];
    [self.task resume];
}
- (void)exportReport {
    NSString *report = [NSString stringWithFormat:@"%@\n%@", self.report ? self.report() : @"", self.connectionResult ?: @""];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[report] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:share animated:YES completion:nil];
}
- (void)retryPlayback { [self.task cancel]; [self dismissViewControllerAnimated:YES completion:self.retry]; }
- (void)done { [self.task cancel]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)dealloc { [self.task cancel]; }
@end

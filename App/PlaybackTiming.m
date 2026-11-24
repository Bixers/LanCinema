#import "PlaybackTiming.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static NSString *DelayKey(NSString *scope) {
    NSData *data = [(scope ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *key = [@"audioDelayV1:" mutableCopy];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [key appendFormat:@"%02x", digest[i]];
    return key;
}
NSInteger LCAudioDelayMilliseconds(NSString *scope) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:DelayKey(scope)];
    if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return 0;
    return MAX(-2000, MIN(2000, [value integerValue]));
}
void LCSetAudioDelayMilliseconds(NSString *scope, NSInteger milliseconds) {
    [NSUserDefaults.standardUserDefaults setInteger:MAX(-2000, MIN(2000, milliseconds)) forKey:DelayKey(scope)];
}

@implementation LCAudioTimingController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"音画校准";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionHeaderHeight = 44;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionFooterHeight = 100;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStylePlain target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem.tintColor = UIColor.labelColor;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 1 : 3; }
- (NSString *)sectionHeader:(NSInteger)section {
    return section == 0 ? @"同步优先" : @"当前视频微调";
}
- (NSString *)sectionFooter:(NSInteger)section {
    return section == 0 ? @"声音和画面由同一播放器时钟调度。进入视频或拖动后允许更多缓冲。" : @"只在仍有固定偏差时微调。每次 50 毫秒，范围 ±2 秒；按当前视频保存在此手机。切换耳机或扬声器后可能需要重新校准。";
}
- (UIView *)sectionText:(NSString *)text header:(BOOL)header section:(NSInteger)section {
    UITableViewHeaderFooterView *view = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:nil];
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote compatibleWithTraitCollection:self.traitCollection];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.textColor = UIColor.labelColor;
    label.accessibilityIdentifier = [NSString stringWithFormat:@"audioCalibration%@%ld", header ? @"Header" : @"Footer", (long)section];
    if (header) label.accessibilityTraits |= UIAccessibilityTraitHeader;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [view.contentView addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:view.contentView.layoutMarginsGuide.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:view.contentView.layoutMarginsGuide.trailingAnchor],
        [label.topAnchor constraintEqualToAnchor:view.contentView.topAnchor constant:header ? 16 : 8],
        [label.bottomAnchor constraintEqualToAnchor:view.contentView.bottomAnchor constant:-8]]];
    return view;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [self sectionText:[self sectionHeader:section] header:YES section:section];
}
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [self sectionText:[self sectionFooter:section] header:NO section:section];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (![previous.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory]) [self.tableView reloadData];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.textProperties.numberOfLines = 0; content.secondaryTextProperties.numberOfLines = 0;
    NSInteger delay = LCAudioDelayMilliseconds(self.scope);
    if (indexPath.section == 0) {
        content.text = @"已启用统一音视频时钟";
        content.secondaryText = delay == 0 ? @"额外补偿：0 毫秒" : [NSString stringWithFormat:@"声音%@ %ld 毫秒", delay > 0 ? @"延后" : @"提前", (long)labs(delay)];
        content.image = [UIImage systemImageNamed:@"waveform.path"];
        cell.accessibilityIdentifier = @"audioSyncStatus";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSArray *titles = @[@"声音早了：延后 50 毫秒", @"声音晚了：提前 50 毫秒", @"恢复默认补偿"];
        NSArray *identifiers = @[@"delayAudio", @"advanceAudio", @"resetAudioDelay"];
        content.text = titles[indexPath.row]; content.textProperties.color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? UIColor.systemTealColor : [UIColor colorWithRed:0 green:.4 blue:.42 alpha:1];
        }];
        cell.accessibilityIdentifier = identifiers[indexPath.row];
    }
    cell.contentConfiguration = content;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    NSInteger delay = LCAudioDelayMilliseconds(self.scope);
    delay = indexPath.row == 0 ? delay + 50 : (indexPath.row == 1 ? delay - 50 : 0);
    LCSetAudioDelayMilliseconds(self.scope, delay);
    if (self.changed) self.changed(LCAudioDelayMilliseconds(self.scope));
    [tableView reloadData];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

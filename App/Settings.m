#import "Settings.h"
#import "Connection.h"
#import "PlaybackOrientation.h"

@implementation LCSettingsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"播放" : @"电脑"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"开启后，进入视频自动横屏；关闭后，播放器跟随手机方向。退出视频恢复竖屏。设置自动保存在此手机。" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.section == 0) {
        // Stacking at accessibility sizes leaves the complete title readable.
        UILabel *label = [UILabel new];
        label.text = @"播放时自动横屏";
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.adjustsFontForContentSizeCategory = YES;
        label.numberOfLines = 0;
        label.isAccessibilityElement = NO;
        UISwitch *toggle = [UISwitch new];
        toggle.on = LCAutomaticPlaybackLandscape();
        toggle.onTintColor = UIColor.systemTealColor;
        toggle.accessibilityLabel = label.text;
        toggle.accessibilityIdentifier = @"automaticPlaybackLandscape";
        [toggle addTarget:self action:@selector(changeLandscape:) forControlEvents:UIControlEventValueChanged];
        [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [toggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
        row.axis = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
        row.alignment = row.axis == UILayoutConstraintAxisVertical ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
        row.spacing = 12; row.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
            [row.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
            [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:56]]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        UIListContentConfiguration *content = [cell defaultContentConfiguration];
        content.text = @"连接电脑"; content.textProperties.numberOfLines = 0;
        content.image = [UIImage systemImageNamed:@"network"];
        cell.contentConfiguration = content;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (![previous.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory]) [self.tableView reloadData];
}
- (void)changeLandscape:(UISwitch *)sender { LCSetAutomaticPlaybackLandscape(sender.on); }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    ConnectionController *connection = [ConnectionController new];
    connection.onConnected = self.onConnected;
    [self.navigationController pushViewController:connection animated:YES];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

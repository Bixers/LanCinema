#import "Connection.h"
#import <Security/Security.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <CoreImage/CoreImage.h>
#import <arpa/inet.h>

static NSDictionary *PasswordQuery(void) {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:@"local.bixer.LanCinema", (__bridge id)kSecAttrAccount:@"computerPassword"};
}
NSString *LCPassword(void) {
    NSMutableDictionary *q = [PasswordQuery() mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &data) == errSecSuccess) {
        return [[NSString alloc] initWithData:CFBridgingRelease(data) encoding:NSUTF8StringEncoding] ?: @"";
    }
    return [NSUserDefaults.standardUserDefaults stringForKey:@"computerAccessCode"] ?: @"";
}
BOOL LCStorePassword(NSString *password) {
    NSDictionary *value = @{(__bridge id)kSecValueData:[password dataUsingEncoding:NSUTF8StringEncoding]};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)PasswordQuery(), (__bridge CFDictionaryRef)value);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *q = [PasswordQuery() mutableCopy];
        [q addEntriesFromDictionary:value];
        q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    }
    if (status == errSecSuccess) [NSUserDefaults.standardUserDefaults removeObjectForKey:@"computerAccessCode"];
    return status == errSecSuccess;
}
static BOOL IsLocalAddress(NSString *host) {
    if (![host isKindOfClass:NSString.class] || !host.length) return NO;
    struct in_addr addr;
    if (inet_pton(AF_INET, host.UTF8String, &addr) != 1) return NO;
    uint32_t value = ntohl(addr.s_addr);
    return (value >> 24) == 10 || (value >> 24) == 127 || (value >> 16) == 0xc0a8 || (value >> 20) == 0xac1 || (value >> 16) == 0xa9fe;
}
NSDictionary *LCParseQR(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithString:value];
    if (![c.scheme isEqualToString:@"lancinema"] || ![c.host isEqualToString:@"connect"] || c.user || c.password || c.fragment) return nil;
    NSMutableDictionary *items = [NSMutableDictionary new];
    for (NSURLQueryItem *item in c.queryItems) {
        if (items[item.name] || !item.value) return nil;
        items[item.name] = item.value;
    }
    if (![items[@"v"] isEqualToString:@"1"] || ![items[@"port"] isEqualToString:@"8123"] ||
        !IsLocalAddress(items[@"host"]) || [items[@"password"] length] < 8 || [items[@"password"] length] > 128) return nil;
    return items;
}
NSString *LCQRCodeFromImage(UIImage *image) {
    if (!image.CGImage) return nil;
    CIContext *context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:context options:@{CIDetectorAccuracy:CIDetectorAccuracyHigh}];
    CIImage *ci = [[CIImage alloc] initWithCGImage:image.CGImage];
    for (CIQRCodeFeature *feature in [detector featuresInImage:ci]) if (LCParseQR(feature.messageString)) return feature.messageString;
    return nil;
}

@interface ScannerController : UIViewController <AVCaptureMetadataOutputObjectsDelegate, PHPickerViewControllerDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *preview;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, copy) void (^onCode)(NSString *);
@property(nonatomic, strong) dispatch_queue_t cameraQueue;
@property(nonatomic) BOOL finished;
@end
@implementation ScannerController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"扫码连接";
    self.view.backgroundColor = UIColor.blackColor;
    self.cameraQueue = dispatch_queue_create("camera", DISPATCH_QUEUE_SERIAL);
    self.session = [AVCaptureSession new];
    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer addSublayer:self.preview];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.message = [UILabel new];
    self.message.text = @"将电脑端的连接二维码放入画面";
    self.message.numberOfLines = 0;
    self.message.textColor = UIColor.whiteColor;
    self.message.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    self.message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.message.adjustsFontForContentSizeCategory = YES;
    self.message.textAlignment = NSTextAlignmentCenter;
    UIButton *photo = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"从相册读取二维码";
    config.contentInsets = NSDirectionalEdgeInsetsMake(14, 20, 14, 20);
    photo.configuration = config;
    [photo addTarget:self action:@selector(photos) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.message, photo]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24], [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24], [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24]]];
    __weak typeof(self) weakSelf = self;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        if (!granted) { dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.message.text = @"未开启相机权限。可在系统设置中允许，或从相册读取二维码。"; }); return; }
        dispatch_async(weakSelf.cameraQueue, ^{
            ScannerController *s = weakSelf;
            if (!s || s.finished) return;
            NSError *error;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo] error:&error];
            AVCaptureMetadataOutput *output = [AVCaptureMetadataOutput new];
            if (!input || ![s.session canAddInput:input]) { dispatch_async(dispatch_get_main_queue(), ^{ s.message.text = @"相机不可用，请从相册读取二维码。"; }); return; }
            [s.session addInput:input];
            if (![s.session canAddOutput:output]) return;
            [s.session addOutput:output];
            [output setMetadataObjectsDelegate:s queue:dispatch_get_main_queue()];
            output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
            [s.session startRunning];
        });
    }];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; self.preview.frame = self.view.bounds; }
- (void)cancel { self.finished = YES; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; dispatch_async(self.cameraQueue, ^{ [self.session stopRunning]; }); }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if (!self.finished && self.session.inputs.count) dispatch_async(self.cameraQueue, ^{ [self.session startRunning]; }); }
- (void)accept:(NSString *)value {
    if (self.finished) return;
    if (!LCParseQR(value)) { self.message.text = @"这不是有效的局域影院连接码，请扫描电脑端显示的二维码。"; return; }
    self.finished = YES;
    [self dismissViewControllerAnimated:YES completion:^{ if (self.onCode) self.onCode(value); }];
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)objects fromConnection:(AVCaptureConnection *)connection {
    for (AVMetadataMachineReadableCodeObject *code in objects) if (code.stringValue) { [self accept:code.stringValue]; break; }
}
- (void)photos {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = PHPickerFilter.imagesFilter; config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class]) return;
    [provider loadObjectOfClass:UIImage.class completionHandler:^(__kindof id<NSItemProviderReading> image, NSError *error) {
        UIImage *picture = (UIImage *)image;
        NSString *value = LCQRCodeFromImage(picture);
        dispatch_async(dispatch_get_main_queue(), ^{ if (value) [self accept:value]; else self.message.text = @"图片中没有有效的连接二维码，请重新选择。"; });
    }];
}
@end

@interface ConnectionController () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property(nonatomic, strong) NSNetServiceBrowser *browser;
@property(nonatomic, strong) NSMutableArray<NSNetService *> *services;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *hosts;
@property(nonatomic, strong) UITextField *host;
@property(nonatomic, strong) UITextField *password;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *computer;
@property(nonatomic, strong) UIButton *connect;
@property(nonatomic, strong) UIStackView *passwordFields;
@property(nonatomic, strong) UIStackView *scanFields;
@property(nonatomic, strong) UISegmentedControl *mode;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@end
@implementation ConnectionController
- (UILabel *)label:(NSString *)text {
    UILabel *label = [UILabel new]; label.text = text; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; label.adjustsFontForContentSizeCategory = YES;
    return label;
}
- (UIButton *)button:(NSString *)text action:(SEL)action filled:(BOOL)filled {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *c = filled ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration tintedButtonConfiguration];
    c.title = text; c.contentInsets = NSDirectionalEdgeInsetsMake(14, 16, 14, 16); button.configuration = c;
    button.titleLabel.numberOfLines = 0;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (UITextField *)field:(NSString *)name {
    UITextField *f = [UITextField new]; f.borderStyle = UITextBorderStyleRoundedRect;
    f.accessibilityLabel = name; f.placeholder = name; f.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    f.adjustsFontForContentSizeCategory = YES; f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo;
    [f.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return f;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"连接电脑"; self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.services = [NSMutableArray new]; self.hosts = [NSMutableDictionary new];
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    self.mode = [[UISegmentedControl alloc] initWithItems:@[@"密码连接", @"扫码连接"]];
    self.mode.selectedSegmentIndex = [NSUserDefaults.standardUserDefaults integerForKey:@"connectionMode"];
    [self.mode.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.mode addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    self.computer = [self button:@"正在查找电脑…" action:@selector(refreshDiscovery) filled:NO];
    self.host = [self field:@"电脑地址"];
    self.host.text = [NSUserDefaults.standardUserDefaults stringForKey:@"computerHost"];
    self.host.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.password = [self field:@"连接密码"];
    self.password.secureTextEntry = YES; self.password.textContentType = UITextContentTypePassword; self.password.text = LCPassword();
    UIButton *reveal = [self button:@"显示密码" action:@selector(revealPassword:) filled:NO];
    self.connect = [self button:@"连接" action:@selector(connectPassword) filled:YES];
    self.passwordFields = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:@"局域网电脑"], self.computer, [self label:@"电脑地址（自动发现，也可手动填写）"], self.host, [self label:@"电脑端设置的连接密码"], self.password, reveal, self.connect]];
    self.passwordFields.axis = UILayoutConstraintAxisVertical; self.passwordFields.spacing = 12;
    UIButton *scan = [self button:@"扫描电脑二维码" action:@selector(scan) filled:YES];
    self.scanFields = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:@"打开电脑端「局域影院」，扫描右侧二维码。地址和密码将自动填写并连接。"], scan]];
    self.scanFields.axis = UILayoutConstraintAxisVertical; self.scanFields.spacing = 20;
    self.status = [self label:@""];
    self.status.textColor = UIColor.secondaryLabelColor;
    self.status.accessibilityIdentifier = @"connectionStatus";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:@"手机与电脑连接同一 Wi-Fi 或局域网。共享文件夹在电脑端选择。"], self.mode, self.passwordFields, self.scanFields, self.status]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24], [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24], [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]]];
    [self modeChanged]; [self refreshDiscovery];
}
- (void)modeChanged {
    self.passwordFields.hidden = self.mode.selectedSegmentIndex != 0;
    self.scanFields.hidden = self.mode.selectedSegmentIndex == 0;
    [NSUserDefaults.standardUserDefaults setInteger:self.mode.selectedSegmentIndex forKey:@"connectionMode"];
    [self.view endEditing:YES];
}
- (void)revealPassword:(UIButton *)button {
    self.password.secureTextEntry = !self.password.secureTextEntry;
    UIButtonConfiguration *c = button.configuration; c.title = self.password.secureTextEntry ? @"显示密码" : @"隐藏密码"; button.configuration = c;
}
- (void)refreshDiscovery {
    [self.browser stop]; [self.services removeAllObjects]; [self.hosts removeAllObjects];
    self.browser = [NSNetServiceBrowser new]; self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_lancinema._tcp." inDomain:@"local."];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!weakSelf.hosts.count) {
            UIButtonConfiguration *c = weakSelf.computer.configuration; c.title = @"未发现电脑 · 点击重新查找"; weakSelf.computer.configuration = c;
            weakSelf.status.text = @"未发现时，可直接扫码或填写电脑端显示的地址。";
        }
    });
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    [self.services addObject:service]; service.delegate = self; [service resolveWithTimeout:6];
}
- (void)netServiceDidResolveAddress:(NSNetService *)service {
    for (NSData *data in service.addresses) {
        const struct sockaddr *address = data.bytes;
        if (address->sa_family != AF_INET) continue;
        char value[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &((const struct sockaddr_in *)address)->sin_addr, value, sizeof(value));
        NSString *host = @(value); if (!IsLocalAddress(host)) continue;
        self.hosts[[NSString stringWithFormat:@"%@ · %@", service.name, host]] = host;
        if (!self.host.text.length) self.host.text = host;
    }
    NSMutableArray *actions = [NSMutableArray new];
    __weak typeof(self) weakSelf = self;
    for (NSString *name in [self.hosts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [actions addObject:[UIAction actionWithTitle:name image:[UIImage systemImageNamed:@"desktopcomputer"] identifier:nil handler:^(UIAction *action) { weakSelf.host.text = weakSelf.hosts[name]; }]];
    }
    if (actions.count) {
        UIButtonConfiguration *c = self.computer.configuration; c.title = @"选择已发现的电脑"; self.computer.configuration = c;
        self.computer.menu = [UIMenu menuWithChildren:actions]; self.computer.showsMenuAsPrimaryAction = YES;
    }
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict {
    self.status.text = @"自动发现不可用。可扫码连接，或填写电脑端显示的地址。请确认已允许本地网络权限。";
}
- (void)connectPassword { [self connectHost:[self.host.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] password:self.password.text]; }
- (void)connectHost:(NSString *)host password:(NSString *)password {
    if (!IsLocalAddress(host) || !password.length) { self.status.text = @"请选择电脑或填写局域网 IPv4 地址，并输入密码。"; return; }
    [self.view endEditing:YES]; [self.task cancel];
    self.connect.enabled = NO; self.status.text = @"正在验证密码并连接…";
    NSURLComponents *c = [NSURLComponents new]; c.scheme = @"http"; c.host = host; c.port = @8123; c.path = @"/api/info";
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"token" value:password]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:c.URL]; request.timeoutInterval = 10;
    __weak typeof(self) weakSelf = self;
    self.task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            ConnectionController *s = weakSelf; if (!s) return; s.connect.enabled = YES;
            if ([(NSHTTPURLResponse *)response statusCode] != 200 || ![json isKindOfClass:NSDictionary.class] || ![json[@"root"] isKindOfClass:NSString.class]) {
                s.status.text = [(NSHTTPURLResponse *)response statusCode] == 401 ? @"密码不正确，请输入电脑端当前的密码。" : @"无法连接。请确认电脑端已启动、设备处于同一局域网，并允许本地网络访问。"; return;
            }
            if (!LCStorePassword(password)) { s.status.text = @"密码未能安全保存，请重试。"; return; }
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            [d setObject:host forKey:@"computerHost"]; [d setObject:json[@"root"] forKey:@"sharedRoot"];
            [d setObject:json[@"libraryID"] ?: @"" forKey:@"libraryID"];
            [s dismissViewControllerAnimated:YES completion:^{ if (s.onConnected) s.onConnected(); }];
        });
    }]; [self.task resume];
}
- (void)scan {
    ScannerController *scanner = [ScannerController new];
    __weak typeof(self) weakSelf = self;
    scanner.onCode = ^(NSString *value) { NSDictionary *items = LCParseQR(value); if (items) [weakSelf connectHost:items[@"host"] password:items[@"password"]]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:scanner]; nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)cancel { [self.task cancel]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)dealloc { [self.browser stop]; for (NSNetService *service in self.services) [service stop]; [self.task cancel]; }
@end

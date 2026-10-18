#import "ViewController.h"
#import <notify.h>

// 必须与 Tweak.xm 中读取的 suite / key 完全一致，否则配置不生效。
static NSString *const kSuite   = @"com.custom.appstoreversionspoofer";
static NSString *const kEnable  = @"enableSpoof";
static NSString *const kFakeVer  = @"fakeVer";
static NSString *const kDefaultFakeVer = @"15.0";

@interface ViewController ()
@property (nonatomic, strong) UISwitch    *enableSwitch;
@property (nonatomic, strong) UITextField *versionField;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"App Store 版本伪装";
    self.view.backgroundColor = [UIColor whiteColor];

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    BOOL enabled = [defaults boolForKey:kEnable];
    NSString *ver = [defaults stringForKey:kFakeVer];
    if (ver.length == 0) ver = kDefaultFakeVer;

    CGFloat w = self.view.bounds.size.width;
    CGFloat y = 20;

    // 说明
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 40)];
    tip.text = @"伪装 iOS 系统版本号，绕过 App Store 的版本校验。";
    tip.font = [UIFont boldSystemFontOfSize:15];
    tip.numberOfLines = 0;
    [tip sizeToFit];
    tip.frame = CGRectMake(20, y, w - 40, tip.frame.size.height);
    [self.view addSubview:tip];
    y += tip.frame.size.height + 24;

    // 启用开关
    UILabel *enableLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 100, 30)];
    enableLabel.text = @"启用版本伪装";
    enableLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:enableLabel];

    self.enableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 80, y, 0, 0)];
    self.enableSwitch.on = enabled;
    [self.view addSubview:self.enableSwitch];
    y += 50;

    // 版本号输入
    UILabel *verLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 100, 30)];
    verLabel.text = @"伪装 iOS 版本号";
    verLabel.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:verLabel];

    self.versionField = [[UITextField alloc] initWithFrame:CGRectMake(w - 180, y, 160, 30)];
    self.versionField.borderStyle = UITextBorderStyleRoundedRect;
    self.versionField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.versionField.placeholder = @"例如 15.0";
    self.versionField.text = ver;
    self.versionField.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.versionField];
    y += 50;

    // 保存按钮
    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(20, y, w - 40, 46);
    [apply setTitle:@"保存并重启 SpringBoard 生效" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [apply addTarget:self action:@selector(applyTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:apply];
    y += 60;

    // 风险提示
    UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w - 40, 120)];
    note.text = @"仅供个人学习研究。伪造系统版本绕过 App Store 校验违反 Apple 用户协议，可能导致 Apple ID 封禁或设备异常，风险自担。";
    note.font = [UIFont systemFontOfSize:12];
    note.textColor = [UIColor grayColor];
    note.numberOfLines = 0;
    [self.view addSubview:note];

    // 点击空白处收起键盘
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)]];
}

- (void)dismissKeyboard {
    [self.versionField resignFirstResponder];
}

- (void)applyTapped:(id)sender {
    [self.versionField resignFirstResponder];

    NSString *v = self.versionField.text;
    if (v.length == 0) v = kDefaultFakeVer;

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
    [defaults setBool:self.enableSwitch.on forKey:kEnable];
    [defaults setObject:v forKey:kFakeVer];
    [defaults synchronize];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已保存"
        message:@"配置已写入，正在重启 SpringBoard 使设置对 App Store 生效。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * _Nonnull action) {
            notify_post("com.apple.springboard.reboot");
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

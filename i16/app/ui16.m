// ui16.m —— 把面板画成 iOS 16 的样子
//
// 这个界面本身是一个论证：如果 shim 真的补上了 iOS 13–16 的那几项，
// 那它就应该能画出 iOS 16 的界面 —— 12.2 自己的控件库画不出来。
//
// 为什么不用 UITableView 而是手排 UIScrollView：
//   iOS 16 那种 inset grouped 列表，卡片是**跨 cell** 的 —— 一张白底圆角卡片
//   包住整组行，行之间有分隔线、首尾行有圆角。UITableView 是「一格一个视图」，
//   在 cell 里画卡片就得判断自己是首行还是末行，还要跟系统的分隔线、选中背景、
//   复用残留打架。12 项内容，手排更短也更准。
//
// 为什么每一处都用 frame 而不是 Auto Layout：
//   尺寸全是常量，且要在 12.2 上稳定。frame 的布局结果可以直接算出来，
//   不用在设备上猜约束冲突。
//
// 文字与颜色全部走 shim：
//   12.4 的 SDK 里没有 labelColor 这类声明，直接写是编译错误。
//   所以统一走 NSSelectorFromString —— 界面上每一处颜色真的来自那一层。

#import "ui16.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/sysctl.h>

#pragma clang diagnostic ignored "-Wundeclared-selector"

// ============================================================ 编译期声明
// 只声明，实现是运行时加的。
// UIImageSymbolConfiguration 这个类名**不能**直接写：写类名会在链接期产生
// _OBJC_CLASS_$_ 符号，而 12.2 没有这个类，注入到别的 App 里就链接失败。
// 所以下面一律走 NSClassFromString。
@interface UIImage (I16SymbolUI)
+ (UIImage *)systemImageNamed:(NSString *)name;
+ (UIImage *)systemImageNamed:(NSString *)name withConfiguration:(id)configuration;
@end

// ============================================================ 语义色
// 取不到就退回等价的具体值 —— 降级也要有颜色，不能白屏。
static UIColor *I16C(NSString *name, UIColor *fallback) {
    SEL s = NSSelectorFromString(name);
    if (![[UIColor class] respondsToSelector:s]) return fallback;
    UIColor *c = ((id (*)(id, SEL))objc_msgSend)([UIColor class], s);
    return c ?: fallback;
}

static UIColor *I16Label(void)     { return I16C(@"labelColor", [UIColor blackColor]); }
static UIColor *I16Label2(void)    { return I16C(@"secondaryLabelColor", [UIColor grayColor]); }
static UIColor *I16Label3(void)    { return I16C(@"tertiaryLabelColor", [UIColor lightGrayColor]); }
static UIColor *I16BGGrouped(void) { return I16C(@"systemGroupedBackgroundColor", [UIColor groupTableViewBackgroundColor]); }
static UIColor *I16BGCard(void)    { return I16C(@"secondarySystemGroupedBackgroundColor", [UIColor whiteColor]); }
static UIColor *I16Sep(void)       { return I16C(@"separatorColor", [UIColor lightGrayColor]); }
static UIColor *I16Blue(void)      { return I16C(@"systemBlueColor", [UIColor blueColor]); }
static UIColor *I16Green(void)     { return I16C(@"systemGreenColor", [UIColor greenColor]); }
static UIColor *I16Orange(void)    { return I16C(@"systemOrangeColor", [UIColor orangeColor]); }
static UIColor *I16Red(void)       { return I16C(@"systemRedColor", [UIColor redColor]); }
static UIColor *I16Purple(void)    { return I16C(@"systemPurpleColor", [UIColor purpleColor]); }
static UIColor *I16Teal(void)      { return I16C(@"systemTealColor", [UIColor cyanColor]); }
static UIColor *I16Indigo(void)    { return I16C(@"systemIndigoColor", [UIColor blueColor]); }
static UIColor *I16Pink(void)      { return I16C(@"systemPinkColor", [UIColor magentaColor]); }
static UIColor *I16Gray(void)      { return I16C(@"systemGrayColor", [UIColor grayColor]); }

// ============================================================ 符号
// 先问一句 respondsToSelector：没装 shim 的进程里直接调会崩。
// 这不是多余的防护 —— ui16 也可能被编进注入版 dylib。
static BOOL I16UIHasSymbols(void) {
    return [[UIImage class] respondsToSelector:@selector(systemImageNamed:)];
}

static UIImage *I16Sym(NSString *name, CGFloat pt) {
    if (!name.length || !I16UIHasSymbols()) return nil;
    Class cfgCls = NSClassFromString(@"UIImageSymbolConfiguration");
    if (cfgCls && [cfgCls respondsToSelector:@selector(configurationWithPointSize:)]) {
        id cfg = ((id (*)(id, SEL, CGFloat))objc_msgSend)
                 (cfgCls, @selector(configurationWithPointSize:), pt);
        if (cfg && [[UIImage class] respondsToSelector:@selector(systemImageNamed:withConfiguration:)]) {
            return [UIImage systemImageNamed:name withConfiguration:cfg];
        }
    }
    return [UIImage systemImageNamed:name];
}

// ============================================================ 布局常量
static const CGFloat kSide       = 20.0;   // 页边距
static const CGFloat kCardInset  = 16.0;   // 卡片内边距
static const CGFloat kIconSize   = 30.0;
static const CGFloat kIconGap    = 14.0;
static const CGFloat kRowH       = 58.0;
static const CGFloat kCardRadius = 12.0;
static const CGFloat kMaxWidth   = 700.0;  // iPad 横屏 1194pt，太宽会散

static CGFloat I16ContentWidth(CGFloat viewW) {
    CGFloat w = viewW - kSide * 2;
    return w > kMaxWidth ? kMaxWidth : w;
}

// 多行文本高度。12.2 上 -sizeThatFits: 对多行 UILabel 不可靠，用 boundingRect。
static CGFloat I16TextH(NSString *text, UIFont *font, CGFloat width) {
    if (!text.length || width <= 0) return 0;
    CGRect r = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin |
                                          NSStringDrawingUsesFontLeading
                               attributes:@{ NSFontAttributeName: font }
                                  context:nil];
    return ceil(r.size.height);
}

// ============================================================ 状态外观
static UIColor *I16StateTint(I16State s) {
    switch (s) {
        case I16StateNative: return I16Gray();
        case I16StateShim:   return I16Green();
        case I16StateApprox: return I16Orange();
        case I16StateGap:    return I16Red();
    }
    return I16Gray();
}

// 每项一个图标 + 一个分类色。图标名都在 i16symbols.json 里核过。
// 取不到就是 nil，图标块退化成首字母 —— 不崩，也不留空。
static NSDictionary *I16IconTable(void) {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{ @"语义色":       @[ @"paintpalette.fill",       @"systemPurpleColor" ],
               @"文件类型":     @[ @"tag.fill",               @"systemBlueColor" ],
               @"菜单":         @[ @"list.bullet",            @"systemOrangeColor" ],
               @"列表外观":     @[ @"tablecells",             @"systemTealColor" ],
               @"SF Symbols":   @[ @"sparkles",               @"systemPinkColor" ],
               @"深色模式":     @[ @"moon.fill",              @"systemIndigoColor" ],
               @"场景生命周期": @[ @"rectangle.on.rectangle", @"systemBlueColor" ],
               @"SwiftUI":      @[ @"swift",                  @"systemOrangeColor" ],
               @"Combine":      @[ @"repeat",                 @"systemGreenColor" ],
               @"组合布局":     @[ @"square.grid.2x2.fill",   @"systemPurpleColor" ],
               @"差异数据源":   @[ @"arrow.left.arrow.right", @"systemTealColor" ],
               @"触觉引擎":     @[ @"hand.tap.fill",          @"systemRedColor" ] };
    });
    return m;
}

static NSString *I16FeatureSymbol(NSString *title) {
    NSArray *v = I16IconTable()[title];
    return v.count ? v[0] : @"square.fill";
}

static UIColor *I16FeatureTint(NSString *title) {
    NSArray *v = I16IconTable()[title];
    return I16C(v.count ? v[1] : @"systemBlueColor", I16Blue());
}

// ============================================================ 图标块
// 30x30 圆角方块，底色是该项的分类色，中间白色符号。
// iOS 13 起 systemImageNamed: 的常规用法就是这样 —— 所以它同时是这一项的展示。
@interface I16IconView : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *letter;
- (void)setSymbol:(NSString *)name tint:(UIColor *)tint;
@end

@implementation I16IconView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.layer.cornerRadius = 7.0;
    self.layer.masksToBounds = YES;
    self.backgroundColor = I16Blue();

    _imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.tintColor = [UIColor whiteColor];
    [self addSubview:_imageView];

    _letter = [[UILabel alloc] initWithFrame:CGRectZero];
    _letter.textAlignment = NSTextAlignmentCenter;
    _letter.textColor = [UIColor whiteColor];
    _letter.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _letter.hidden = YES;
    [self addSubview:_letter];
    return self;
}

- (void)setSymbol:(NSString *)name tint:(UIColor *)tint {
    self.backgroundColor = tint ?: I16Blue();
    UIImage *img = I16Sym(name, 17.0);
    if (img) {
        self.imageView.image = img;
        self.imageView.hidden = NO;
        self.letter.hidden = YES;
    } else {
        self.imageView.hidden = YES;
        self.letter.hidden = NO;
        self.letter.text = name.length ? [[name substringToIndex:1] uppercaseString] : @"?";
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    // 符号按 17pt 光栅化，放进 30pt 的块：等比缩放，不能拉歪。
    CGSize is = self.imageView.image.size;
    CGFloat w = is.width, h = is.height;
    if (w > 0 && h > 0) {
        CGFloat maxSide = s.width * 0.62;
        CGFloat k = MIN(maxSide / w, maxSide / h);
        w *= k; h *= k;
    }
    self.imageView.frame = CGRectMake((s.width - w) / 2, (s.height - h) / 2, w, h);
    self.letter.frame = self.bounds;
}

@end

// ============================================================ 行
@interface I16RowView : UIControl
@property (nonatomic, strong) I16Feature *feature;
@property (nonatomic, strong) I16IconView *icon;
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UILabel *sub;
@property (nonatomic, strong) UILabel *meta;
@property (nonatomic, strong) UIImageView *chev;
@property (nonatomic, assign) BOOL showSeparator;
@property (nonatomic, strong) UIView *sep;
- (void)configureWith:(I16Feature *)f;
@end

@implementation I16RowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _icon  = [[I16IconView alloc] initWithFrame:CGRectZero];
    _title = [[UILabel alloc] initWithFrame:CGRectZero];
    _sub   = [[UILabel alloc] initWithFrame:CGRectZero];
    _meta  = [[UILabel alloc] initWithFrame:CGRectZero];
    _chev  = [[UIImageView alloc] initWithFrame:CGRectZero];
    _sep   = [[UIView alloc] initWithFrame:CGRectZero];

    _title.font = [UIFont systemFontOfSize:17];
    _title.textColor = I16Label();

    _sub.font = [UIFont systemFontOfSize:12];
    _sub.textColor = I16Label2();
    _sub.lineBreakMode = NSLineBreakByTruncatingTail;

    _meta.font = [UIFont systemFontOfSize:12];
    _meta.textAlignment = NSTextAlignmentRight;
    _meta.textColor = I16Label2();

    _chev.contentMode = UIViewContentModeScaleAspectFit;
    _chev.tintColor = I16Label3();
    _sep.backgroundColor = I16Sep();

    [self addSubview:_icon];
    [self addSubview:_title];
    [self addSubview:_sub];
    [self addSubview:_meta];
    [self addSubview:_chev];
    [self addSubview:_sep];
    return self;
}

- (void)configureWith:(I16Feature *)f {
    self.feature = f;
    self.title.text = f.title;
    self.sub.text = f.api;

    self.meta.text = [NSString stringWithFormat:@"%@ · %@",
                      f.since, [I16Catalog labelForState:f.state]];
    self.meta.textColor = I16StateTint(f.state);

    [self.icon setSymbol:I16FeatureSymbol(f.title) tint:I16FeatureTint(f.title)];

    UIImage *c = I16Sym(@"chevron.right", 13.0);
    self.chev.image = c;
    self.chev.hidden = (c == nil);
    [self setNeedsLayout];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    // iOS 16 的行按下是淡灰，不是系统默认的蓝底选中。
    self.backgroundColor = highlighted
        ? [UIColor colorWithWhite:0.0 alpha:0.06]
        : [UIColor clearColor];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;

    self.icon.frame = CGRectMake(kCardInset, (H - kIconSize) / 2, kIconSize, kIconSize);

    CGFloat textX = kCardInset + kIconSize + kIconGap;
    CGFloat chevW = self.chev.hidden ? 0 : 8.0;

    self.chev.frame = CGRectMake(W - kCardInset - chevW, (H - 14) / 2, chevW, 14);

    CGFloat metaW = ceil([self.meta sizeThatFits:CGSizeMake(W, 20)].width);
    CGFloat metaX = W - kCardInset - (chevW > 0 ? chevW + 8 : 0) - metaW;

    CGFloat titleW = metaX - textX - 8;
    if (titleW < 60) titleW = 60;   // 极窄时别把自己压成负宽度

    self.title.frame = CGRectMake(textX, 10, titleW, 21);
    self.sub.frame   = CGRectMake(textX, 31, titleW, 15);
    self.meta.frame  = CGRectMake(metaX, (H - 16) / 2, metaW, 16);

    self.sep.frame = CGRectMake(textX, H - 0.5, W - textX, 0.5);
    self.sep.hidden = !self.showSeparator;
}

@end

// ============================================================ 卡片
@interface I16CardView : UIView
@property (nonatomic, strong) NSMutableArray *rows;
@property (nonatomic, strong) NSArray *features;
@property (nonatomic, copy) void (^onSelect)(I16Feature *);
- (CGFloat)layoutWidth:(CGFloat)w;
@end

@implementation I16CardView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = I16BGCard();
    self.layer.cornerRadius = kCardRadius;
    // 首尾行的圆角靠这一句裁出来 —— iOS 13 的连续圆角曲线没有，
    // 但 12pt 的普通圆角在 2x 屏上肉眼分不出。
    self.layer.masksToBounds = YES;
    _rows = [NSMutableArray array];
    return self;
}

- (void)setFeatures:(NSArray *)features {
    _features = [features copy];
    for (UIView *v in [_rows copy]) [v removeFromSuperview];
    [_rows removeAllObjects];

    for (NSUInteger i = 0; i < features.count; i++) {
        I16RowView *r = [[I16RowView alloc] initWithFrame:CGRectZero];
        [r configureWith:features[i]];
        r.showSeparator = (i + 1 < features.count);
        [r addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:r];
        [_rows addObject:r];
    }
}

- (void)tap:(I16RowView *)sender {
    if (self.onSelect) self.onSelect(sender.feature);
}

// 返回总高，顺手把子视图摆好 —— 父视图只关心高度。
- (CGFloat)layoutWidth:(CGFloat)w {
    CGFloat y = 0;
    for (I16RowView *r in self.rows) {
        r.frame = CGRectMake(0, y, w, kRowH);
        y += kRowH;
    }
    CGRect f = self.frame;
    f.size = CGSizeMake(w, y);
    self.frame = f;
    return y;
}

@end

// ============================================================ 统计条
@interface I16StatBar : UIView
@property (nonatomic, assign) NSInteger nShim, nApprox, nGap;
- (void)setShim:(NSInteger)s approx:(NSInteger)a gap:(NSInteger)g;
@end

@implementation I16StatBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = I16BGCard();
    self.layer.cornerRadius = kCardRadius;
    return self;
}

- (void)setShim:(NSInteger)s approx:(NSInteger)a gap:(NSInteger)g {
    self.nShim = s; self.nApprox = a; self.nGap = g;

    for (UIView *v in [self.subviews copy]) [v removeFromSuperview];

    NSArray *items = @[ @[ @(s), @"已实现", I16Green()  ],
                        @[ @(a), @"近似",   I16Orange() ],
                        @[ @(g), @"不可补", I16Red()    ] ];

    for (NSUInteger i = 0; i < items.count; i++) {
        NSArray *it = items[i];

        UILabel *num = [[UILabel alloc] initWithFrame:CGRectZero];
        num.text = [NSString stringWithFormat:@"%ld", (long)[it[0] integerValue]];
        num.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
        num.textColor = it[2];
        num.textAlignment = NSTextAlignmentCenter;
        num.tag = 100 + i;

        UILabel *cap = [[UILabel alloc] initWithFrame:CGRectZero];
        cap.text = it[1];
        cap.font = [UIFont systemFontOfSize:12];
        cap.textColor = I16Label2();
        cap.textAlignment = NSTextAlignmentCenter;
        cap.tag = 200 + i;

        [self addSubview:num];
        [self addSubview:cap];

        if (i > 0) {
            UIView *div = [[UIView alloc] initWithFrame:CGRectZero];
            div.backgroundColor = I16Sep();
            div.tag = 300 + i;
            [self addSubview:div];
        }
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat cellW = W / 3.0;
    for (NSUInteger i = 0; i < 3; i++) {
        UILabel *num = (UILabel *)[self viewWithTag:100 + i];
        UILabel *cap = (UILabel *)[self viewWithTag:200 + i];
        num.frame = CGRectMake(cellW * i, H / 2 - 28, cellW, 32);
        cap.frame = CGRectMake(cellW * i, H / 2 + 2, cellW, 16);
        if (i > 0) {
            UIView *div = [self viewWithTag:300 + i];
            div.frame = CGRectMake(cellW * i, 18, 0.5, H - 36);
        }
    }
}

@end

// ============================================================ 胶囊
// 12.2 的 UILabel 没有内边距属性，重写两个方法给自己加。
@interface I16Pill : UILabel
@end

@implementation I16Pill
- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)n {
    CGRect r = [super textRectForBounds:bounds limitedToNumberOfLines:n];
    r.size.width += 18; r.size.height += 6;
    return r;
}
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(3, 9, 3, 9))];
}
@end

// ============================================================ 按钮
// 12.2 没有 UIButtonConfiguration，圆角填充按钮只能自己画。
@interface I16FillButton : UIButton
@property (nonatomic, strong) UIColor *fill;
@end

@implementation I16FillButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.layer.cornerRadius = 10.0;
    _fill = I16Blue();
    self.backgroundColor = _fill;
    return self;
}

- (void)setFill:(UIColor *)fill {
    _fill = fill ?: I16Blue();
    self.backgroundColor = _fill;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [self.fill colorWithAlphaComponent:0.78f] : self.fill;
}

@end

// ============================================================ 详情页
@interface I16DetailVC : UIViewController
@property (nonatomic, strong) I16Feature *feature;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSString *result;    // 运行结果，nil = 还没跑
- (instancetype)initWithFeature:(I16Feature *)f;
@end

@implementation I16DetailVC

- (instancetype)initWithFeature:(I16Feature *)f {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _feature = f;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.feature.title;
    self.view.backgroundColor = I16BGGrouped();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.backgroundColor = I16BGGrouped();
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    [self build];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.scroll.frame = self.view.bounds;
    [self build];
}

- (void)run:(id)sender {
    I16Feature *f = self.feature;
    if (!f.demo) {
        self.result = @"这一项标为「不可补」，没有可执行的 demo —— 它缺的是系统通道，不是代码。";
    } else {
        NSString *r = nil;
        @try {
            r = f.demo();
        } @catch (NSException *e) {
            r = [NSString stringWithFormat:@"抛异常 %@: %@", e.name, e.reason];
        }
        self.result = r.length ? r : @"(demo 返回 nil)";
    }
    [self build];
}

- (void)build {
    for (UIView *v in [self.scroll.subviews copy]) [v removeFromSuperview];

    I16Feature *f = self.feature;
    CGFloat viewW = self.view.bounds.size.width;
    CGFloat contentW = I16ContentWidth(viewW);
    CGFloat x0 = (viewW - contentW) / 2;
    CGFloat y = 14;

    // ---- 状态胶囊 + since
    I16Pill *pill = [[I16Pill alloc] initWithFrame:CGRectZero];
    pill.text = [I16Catalog labelForState:f.state];
    pill.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    pill.textColor = [UIColor whiteColor];
    pill.backgroundColor = I16StateTint(f.state);
    pill.layer.cornerRadius = 9.0;
    pill.layer.masksToBounds = YES;
    CGSize ps = [pill sizeThatFits:CGSizeMake(contentW, 30)];
    pill.frame = CGRectMake(x0, y, ps.width, ps.height);
    [self.scroll addSubview:pill];

    UILabel *since = [[UILabel alloc] initWithFrame:
                      CGRectMake(x0 + ps.width + 8, y, contentW - ps.width - 8, ps.height)];
    since.text = [NSString stringWithFormat:@"%@ 引入", f.since];
    since.font = [UIFont systemFontOfSize:13];
    since.textColor = I16Label2();
    [self.scroll addSubview:since];
    y += ps.height + 16;

    // ---- API 名，等宽。这一行要一眼看出「补的是哪个符号」
    UIFont *mono = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    UILabel *api = [[UILabel alloc] initWithFrame:CGRectZero];
    api.text = f.api;
    api.font = mono;
    api.textColor = I16Label2();
    api.numberOfLines = 0;
    CGFloat ah = I16TextH(f.api, mono, contentW - kCardInset * 2);
    UIView *apiCard = [[UIView alloc] initWithFrame:CGRectMake(x0, y, contentW, ah + kCardInset * 2)];
    apiCard.backgroundColor = I16BGCard();
    apiCard.layer.cornerRadius = kCardRadius;
    api.frame = CGRectMake(kCardInset, kCardInset, contentW - kCardInset * 2, ah);
    [apiCard addSubview:api];
    [self.scroll addSubview:apiCard];
    y += apiCard.frame.size.height + 24;

    // ---- 说明
    UILabel *head1 = [[UILabel alloc] initWithFrame:
                      CGRectMake(x0 + kCardInset, y, contentW - kCardInset, 18)];
    head1.text = @"说明";
    head1.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    head1.textColor = I16Label2();
    [self.scroll addSubview:head1];
    y += 18 + 8;

    UIFont *bodyFont = [UIFont systemFontOfSize:15];
    CGFloat nh = I16TextH(f.note, bodyFont, contentW - kCardInset * 2);
    UIView *noteCard = [[UIView alloc] initWithFrame:CGRectMake(x0, y, contentW, nh + kCardInset * 2)];
    noteCard.backgroundColor = I16BGCard();
    noteCard.layer.cornerRadius = kCardRadius;
    UILabel *note = [[UILabel alloc] initWithFrame:
                     CGRectMake(kCardInset, kCardInset, contentW - kCardInset * 2, nh)];
    note.text = f.note;
    note.font = bodyFont;
    note.textColor = I16Label();
    note.numberOfLines = 0;
    [noteCard addSubview:note];
    [self.scroll addSubview:noteCard];
    y += noteCard.frame.size.height + 24;

    // ---- 运行结果
    UILabel *head2 = [[UILabel alloc] initWithFrame:
                      CGRectMake(x0 + kCardInset, y, contentW - kCardInset, 18)];
    head2.text = @"运行结果";
    head2.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    head2.textColor = I16Label2();
    [self.scroll addSubview:head2];
    y += 18 + 8;

    NSString *text = self.result.length ? self.result
                   : (f.demo ? @"还没跑。点下面的按钮，在这台设备上真调一次。" 
                             : @"这一项没有 demo。");
    UIFont *rf = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    CGFloat rh = I16TextH(text, rf, contentW - kCardInset * 2);
    UIView *resCard = [[UIView alloc] initWithFrame:CGRectMake(x0, y, contentW, rh + kCardInset * 2)];
    resCard.backgroundColor = I16BGCard();
    resCard.layer.cornerRadius = kCardRadius;
    UILabel *res = [[UILabel alloc] initWithFrame:
                    CGRectMake(kCardInset, kCardInset, contentW - kCardInset * 2, rh)];
    res.text = text;
    res.font = rf;
    res.textColor = self.result.length ? I16Label() : I16Label2();
    res.numberOfLines = 0;
    [resCard addSubview:res];
    [self.scroll addSubview:resCard];
    y += resCard.frame.size.height + 20;

    // ---- 运行按钮
    I16FillButton *btn = [[I16FillButton alloc]
                          initWithFrame:CGRectMake(x0, y, contentW, 46)];
    [btn setTitle:(self.result.length ? @"再跑一次" : @"运行这项")
         forState:UIControlStateNormal];
    btn.fill = f.demo ? I16Blue() : I16Gray();
    btn.enabled = (f.demo != nil);
    [btn addTarget:self action:@selector(run:) forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:btn];
    y += 46 + 30;

    self.scroll.contentSize = CGSizeMake(viewW, y);
}

@end

// ============================================================ 首页
@interface I16HomeVC : UIViewController
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, assign) CGFloat lastWidth;
@end

@implementation I16HomeVC

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"i16";
    self.view.backgroundColor = I16BGGrouped();
    // 大标题是 iOS 11 的能力，12.2 原生就有 —— 这一处不是 shim 的功劳，
    // 但它是 iOS 16 观感里最容易被认出来的一半。
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    self.items = [I16Catalog all];

    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.backgroundColor = I16BGGrouped();
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    [self build];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.scroll.frame = self.view.bounds;
    [self build];
}

- (void)build {
    if (!self.scroll) return;
    for (UIView *v in [self.scroll.subviews copy]) [v removeFromSuperview];

    CGFloat viewW = self.view.bounds.size.width;
    if (viewW < 1) return;
    // 宽度没变就不重建：viewDidLayoutSubviews 会因为键盘、转场反复触发，
    // 每次都拆了重搭会打断点击高亮，也白费一遍图标光栅化。
    if (fabs(viewW - self.lastWidth) < 0.5 && self.scroll.subviews.count) return;
    self.lastWidth = viewW;

    CGFloat contentW = I16ContentWidth(viewW);
    CGFloat x0 = (viewW - contentW) / 2;
    CGFloat y = 10;

    // ---- 设备行
    UIDevice *d = [UIDevice currentDevice];
    // UIDevice.model 只给 "iPad"，型号细节要问内核。这一行存在的意义就是
    // 让人一眼确认「这是哪台机器上跑出来的」，含糊掉就没用了。
    char machine[64] = {0};
    size_t mlen = sizeof(machine);
    NSString *hw = @"?";
    if (sysctlbyname("hw.machine", machine, &mlen, NULL, 0) == 0 && mlen > 0) {
        hw = [NSString stringWithUTF8String:machine];
    }
    UILabel *dev = [[UILabel alloc] initWithFrame:CGRectMake(x0, y, contentW, 16)];
    dev.text = [NSString stringWithFormat:@"%@ · %@ %@",
                hw, d.systemName, d.systemVersion];
    dev.font = [UIFont systemFontOfSize:12];
    dev.textColor = I16Label2();
    [self.scroll addSubview:dev];
    y += 16 + 10;

    // ---- 说明
    UILabel *blurb = [[UILabel alloc] initWithFrame:CGRectZero];
    blurb.text = @"用 12.2 已有的 API，重写 13 / 14 / 15 / 16 的框架层。";
    blurb.font = [UIFont systemFontOfSize:15];
    blurb.textColor = I16Label2();
    blurb.numberOfLines = 0;
    CGFloat bh = I16TextH(blurb.text, blurb.font, contentW);
    blurb.frame = CGRectMake(x0, y, contentW, bh);
    [self.scroll addSubview:blurb];
    y += bh + 20;

    // ---- 统计
    NSInteger s = 0, a = 0, g = 0;
    for (I16Feature *f in self.items) {
        if (f.state == I16StateShim) s++;
        else if (f.state == I16StateApprox) a++;
        else if (f.state == I16StateGap) g++;
    }
    I16StatBar *bar = [[I16StatBar alloc] initWithFrame:CGRectMake(x0, y, contentW, 88)];
    [bar setShim:s approx:a gap:g];
    [self.scroll addSubview:bar];
    y += 88 + 30;

    // ---- 三组。顺序本身就是结论：能补的在上面，补不了的写明为什么。
    NSArray *groups = @[ @[ @(I16StateShim),   @"已实现" ],
                         @[ @(I16StateApprox), @"近似"   ],
                         @[ @(I16StateGap),    @"不可补" ] ];

    __weak typeof(self) weakSelf = self;
    for (NSArray *g in groups) {
        I16State st = (I16State)[g[0] integerValue];
        NSMutableArray *bucket = [NSMutableArray array];
        for (I16Feature *f in self.items) if (f.state == st) [bucket addObject:f];
        if (!bucket.count) continue;

        UILabel *head = [[UILabel alloc] initWithFrame:
                         CGRectMake(x0 + kCardInset, y, contentW - kCardInset, 18)];
        head.text = g[1];
        head.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        head.textColor = I16Label2();
        [self.scroll addSubview:head];
        y += 18 + 8;

        I16CardView *card = [[I16CardView alloc] initWithFrame:CGRectMake(x0, y, contentW, 0)];
        [card setFeatures:bucket];
        card.onSelect = ^(I16Feature *f) {
            I16DetailVC *dvc = [[I16DetailVC alloc] initWithFeature:f];
            [weakSelf.navigationController pushViewController:dvc animated:YES];
        };
        [self.scroll addSubview:card];
        CGFloat h = [card layoutWidth:contentW];
        y += h + 28;
    }

    // ---- 页脚
    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectZero];
    foot.text = @"每一条都能在这台设备上真跑一遍 —— 点进去，按「运行」。";
    foot.font = [UIFont systemFontOfSize:12];
    foot.textColor = I16Label3();
    foot.textAlignment = NSTextAlignmentCenter;
    foot.numberOfLines = 0;
    CGFloat fh = I16TextH(foot.text, foot.font, contentW);
    foot.frame = CGRectMake(x0, y, contentW, fh);
    [self.scroll addSubview:foot];
    y += fh + 30;

    self.scroll.contentSize = CGSizeMake(viewW, y);
}

@end

// ============================================================ 入口
UIViewController *I16UIRoot(void) {
    // 装。四个模块都是幂等的，装几次都一样。
    I16ColorInstall();
    I16MenuInstall();
    I16TypeInstall();
    I16ListInstall();
    I16SymbolInstall();

    I16HomeVC *home = [[I16HomeVC alloc] initWithNibName:nil bundle:nil];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:home];

    // iOS 16 观感的关键三处：大标题、导航栏与页面同色、不要那条阴影线。
    // 12.2 的 UINavigationBar 支持前两项（iOS 11 / 7），第三项是 shadowImage。
    UINavigationBar *bar = nav.navigationBar;
    bar.prefersLargeTitles = YES;
    bar.translucent = NO;
    bar.barTintColor = I16BGGrouped();
    bar.shadowImage = [UIImage new];
    bar.tintColor = I16Blue();
    bar.titleTextAttributes = @{ NSForegroundColorAttributeName: I16Label() };
    bar.largeTitleTextAttributes = @{
        NSForegroundColorAttributeName: I16Label(),
        NSFontAttributeName: [UIFont systemFontOfSize:34 weight:UIFontWeightBold]
    };
    return nav;
}

// ============================================================ 快照
// 没有触摸注入工具，唯一能「看见」界面的办法就是让界面自己交出一张图。
BOOL I16UISnapshot(NSString *path) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) w = [[[UIApplication sharedApplication] windows] firstObject];
    if (!w || !path.length) return NO;

    UIGraphicsBeginImageContextWithOptions(w.bounds.size, NO, 0);
    BOOL ok = [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:YES];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!ok || !img) return NO;

    NSData *png = UIImagePNGRepresentation(img);
    return [png writeToFile:path atomically:YES];
}

void I16UISnapshotAll(NSString *dir) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    UIViewController *root = w.rootViewController;
    if (![root isKindOfClass:[UINavigationController class]]) return;
    UINavigationController *nav = (UINavigationController *)root;

    NSString *home = [dir stringByAppendingPathComponent:@"i16_home.png"];
    NSString *detail = [dir stringByAppendingPathComponent:@"i16_detail.png"];

    // 等一帧上屏，否则拿到的可能是空白的 backing store。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        I16UISnapshot(home);

        // 详情页拿「语义色」这项做样本：它有 demo，跑完能同时看到
        // 说明卡、结果卡和按钮三种状态。
        I16Feature *pick = nil;
        for (I16Feature *f in [I16Catalog all]) {
            if ([f.title isEqualToString:@"语义色"]) { pick = f; break; }
        }
        if (!pick) return;

        I16DetailVC *d = [[I16DetailVC alloc] initWithFeature:pick];
        [nav pushViewController:d animated:NO];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            I16UISnapshot(detail);
            [nav popViewControllerAnimated:NO];
        });
    });
}

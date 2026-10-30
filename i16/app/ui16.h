// ui16.h —— 面板界面
//
// 这个界面本身是一个论证：如果 shim 真的补上了 iOS 13–16 的那些东西，
// 那它就应该能画出 iOS 16 的界面 —— 而 12.2 自己的控件库画不出来。
//
// 所以这里的每一处视觉都尽量走 shim 的入口：
//   · 背景 / 文字 / 分隔线  → UIColor 的语义色（i16_color.m）
//   · 图标                  → [UIImage systemImageNamed:]（i16_symbol.m）
//   · 行内容                → UIListContentConfiguration（i16_list.m）
// 如果哪一项在设备上没装上，界面要能降级到「没有也不崩」，不是白屏。
// 降级路径见 I16UIHasSymbols()。

#import <UIKit/UIKit.h>
#import "i16.h"

// 根界面。App 的 window.rootViewController 就是它。
FOUNDATION_EXPORT UIViewController *I16UIRoot(void);

// 把当前界面截成 PNG 写到 path。没有触摸注入工具时，这是唯一能
// 「看见」界面长什么样的办法 —— 比起描述布局数值，一张图更算证据。
FOUNDATION_EXPORT BOOL I16UISnapshot(NSString *path);

// 依次渲染首页与详情页，写 i16_home.png / i16_detail.png。
FOUNDATION_EXPORT void I16UISnapshotAll(NSString *dir);

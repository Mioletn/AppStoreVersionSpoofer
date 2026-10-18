# 代码审查报告：AppStoreVersionSpoofer

> 审查维度：Apple HIG 合规、无障碍访问、Swift / Objective-C 最佳实践
> 结论：源码**可编译、结构合理**，但存在 **2 个会导致功能失效/崩溃的真实 Bug** 和若干规范问题，已在本工程修复。

---

## 一、致命 Bug（已修复）

### Bug 1 — `MGCopyAnswer` 返回值所有权错误（必崩）
原代码：
```objc
return (__bridge CFTypeRef)fakeVer;
```
`MGCopyAnswer` 是 CoreFoundation 的 **"Copy" 语义**函数，调用方会对其返回值执行 `CFRelease`。
`__bridge`（非 `__bridge_retained`）**不会增加引用计数**，于是调用方释放了一个它并未持有的对象 →
随机 over-release / 崩溃（EXC_BAD_ACCESS）。

修复：
```objc
return CFRetain((__bridge CFTypeRef)fakeVer);
```
遵循 Copy 所有权契约，调用方 CFRelease 后引用平衡。

### Bug 2 — User-Agent 伪装过滤逻辑错误（功能永不开火）
原代码：
```objc
if([ua containsString:@"MZBuy.woa/wa/buyProduct"]) { ... 替换 UA 中的 iOS 版本 ... }
```
`ua` 是 **User-Agent 字符串**（形如 `AppStore/12.2 ... iOS/12.2 ...`），里面**根本不含请求 URL 路径**
`MZBuy.woa/wa/buyProduct`。该判断几乎永远为 false，导致「服务器侧」伪装从未生效——这是原插件"不工作"的核心原因。

修复：Hook `initWithURL:` / `initWithURL:cachePolicy:timeoutInterval:` 用关联对象捕获请求 URL，
再按 endpoint（`MZBuy` / `buyProduct` / `/buy` / `purchase`）过滤，仅在苹果购买类请求上改写 UA。

---

## 二、规范 / 健壮性（已改进）

| 项 | 原版 | 修复版 |
|---|---|---|
| 重启方式 | `system("killall -9 SpringBoard")` 强制杀进程 | `notify_post("com.apple.springboard.reboot")` 安全通知 |
| 正则编译 | 每次请求 `new` 一个 `NSRegularExpression` | `dispatch_once` 缓存静态实例 |
| 魔法字符串 | `enableSpoof`/`fakeVer` 散落硬编码 | 提取为 `kPref*` 常量 |
| 框架依赖 | 引入未使用的 `IOKit` | 移除，仅保留 `Foundation` |
| 设置面板 | 无风险提示 | 增加 PSGroupCell 风险说明（HIG：提供上下文） |
| 输入键盘 | 版本号用默认键盘 | 指定 `UIKeyboardTypeNumbersAndPunctuation` |

---

## 三、Apple HIG 合规 & 无障碍（设置面板部分）

设置面板基于 `Preferences.framework` 的 specifier 体系，本身由系统渲染，基础可达性较好：

- ✅ **标签可读**：开关 / 文本框 / 按钮均有人类可读 `label`，VoiceOver 默认可读。
- ✅ **分组与上下文**：已补充顶部说明组，符合 HIG「为敏感操作提供解释」原则。
- ⚠️ **触控目标**：系统 PS 单元格默认满足 44pt，无需额外处理。
- ⚠️ **Dynamic Type**：PreferenceLoader 宿主（设置 App）自动跟随系统字号，自定义 cell 无需额外适配。
- ⚠️ **模态/取消**：本插件无模态视图；respring 为显式按钮，符合"用户主动触发"原则（不在启动时静默执行）。
- ⚠️ **色彩不单独表意**：状态通过文字 + 开关表达，未依赖颜色，符合 HIG。

> 注：Tweak 注入的是系统 App Store 进程，其自有 UI 不受本工程控制，HIG 审查主要针对我们提供的**设置面板**。

---

## 四、Swift / Objective-C 最佳实践

- 本项目为 **Objective-C（Logos/Tweak）**，无 Swift 代码；下方按 ObjC 最佳实践评审。
- ✅ 已启用 `-fobjc-arc`，避免手动 retain/release 泄漏（仅 CF 桥接处需显式 `CFRetain`）。
- ✅ 使用 `objc_getAssociatedObject` 传递请求上下文，避免全局可变状态。
- ✅ Hook 前判空（`objc_getClass` 结果），防止进程内不存在该类时崩溃。
- ⚠️ `getFakeVersion` 每次调用都 `alloc` 一个 `NSUserDefaults` 并读盘；高频 `MGCopyAnswer` 调用下略有开销，
  可缓存到静态变量并在 `respring` 时失效，但当前实现已正确且安全，列为可选优化。
- ⚠️ 线程安全：`MGCopyAnswer` 可能多线程调用，读 `NSUserDefaults` 本身线程安全，关联对象读写亦安全，无需加锁。

---

## 五、其余注意事项（沿用原文档，未改动）

1. 下载依赖苹果服务器是否仍保留适配 iOS 12.2 的旧版 IPA。
2. 部分 App 有多重设备/固件硬校验，伪装版本也可能装不上。
3. 风险：绕过版本校验违反 Apple 用户协议，存在 Apple ID 封禁风险，仅限个人学习研究。

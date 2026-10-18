# AppStoreVersionSpoofer（修复版工程）

> ⚠️ **免责声明**：本插件用于 iOS 越狱环境的**个人学习研究**。修改 App Store 请求以绕过版本校验
> 违反 Apple 用户协议，可能导致 Apple ID 封禁、设备异常。请知悉并自行承担全部风险，勿用于任何商业或侵权场景。

iOS 12.2 越狱插件，通过 Hook 让 App Store 识别为更高系统版本，绕过"版本过旧"下载校验，并可自定义伪装版本号。

## 工程结构

```
AppStoreVersionSpoofer/
├── control                         # deb 元数据
├── Makefile                        # 根编译配置（tweak + preference bundle）
├── Tweak.xm                        # 核心 Hook（已修复 2 个 Bug）
├── AppStoreVersionSpoofer.plist    # 注入进程过滤
├── entry.plist                     # PreferenceLoader 入口
├── Preferences/
│   ├── Makefile
│   ├── Root.plist                  # 设置界面 UI（含风险提示）
│   └── RootListController.m        # 设置控制器（安全 respring）
├── .github/workflows/build.yml     # GitHub Actions 自动编译
├── scripts/make_repo.sh            # 生成 Cydia 代码源
└── REVIEW.md                       # 完整代码审查报告
```

## 编译（二选一）

### 方式 A：本地 Theos（macOS / Linux）
```bash
export THEOS=/path/to/theos
make clean
make package FINALPACKAGE=1
# 产物在 packages/*.deb
```

### 方式 B：GitHub Actions（推荐，无需本机工具链）
Push 到含 `.github/workflows/build.yml` 的仓库，Actions 会自动：
1. 安装依赖、拉取 Theos + Linux clang 工具链
2. 用 sparse-checkout 拉取 iOS 12 SDK（`iPhoneOS12.4.sdk`）
3. `make package` 编译
4. 在 Artifacts 处下载 `.deb`

> 注意：`theos/sdks` 现已改为目录形式（旧的 `.tar.xz` 直链已 404），流水线已改用
> `git sparse-checkout set iPhoneOS12.4.sdk`。若 Theos 工具链布局有变动导致失败，
> 把 Actions 报错贴给我，我来调。

### ⚠️ 关于「直接拿到 .deb」
本工程所在环境是 **Windows 沙箱，无 iOS 交叉编译工具链（无 clang / iOS SDK / WSL，
且 WSL 被安全策略禁用）**，因此**无法在此直接编译出 iOS arm64 二进制**。
真正的 `.deb` 必须包含编译好的 `.dylib` 与 `.bundle`，只能在 **macOS / Linux + Theos**
环境下产出——也就是上面方式 A 或方式 B。我不会提供一个缺二进制的「空壳 .deb」。

## 生成为 Cydia 代码源
```bash
./scripts/make_repo.sh
# 生成 repo/（含 .deb、Packages、Packages.gz、Packages.bz2、Release）
# 将 repo/ 整体托管到 HTTPS 空间，在 Cydia/Sileo 添加该 URL 即可。
```

## 使用流程
1. 安装 `.deb` → 重启 SpringBoard
2. 设置 → AppStoreVersionSpoofer → 开启"启用版本伪装"，填伪装版本号 → 点"重启 SpringBoard 生效"
3. App Store 找到目标 App 点【获取】→ 加入已购
4. 回设置**关闭插件**并再次重启 → 返回 App Store 再次【获取】→ 苹果下发适配 iOS 12.2 的旧版 IPA（仅当服务器仍保留）

## 已修复的关键问题
- `MGCopyAnswer` 返回值未 `CFRetain` → over-release 崩溃（已修）
- UA 伪装按 URL 路径判断但 UA 不含 URL → 伪装永不触发（已改按请求 URL 过滤）
- `system("killall -9")` 强制杀进程 → 改为 `notify_post` 安全重启
- 详见 `REVIEW.md`

# macPad — 在 iOS 12.2 / A12X 上跑 macOS 11 用户态二进制
#
# 设备是 arm64e（A12X / T8027）。App 必须包含 arm64e 切片：
# ptrauth 只有在 arm64e 编译目标下才是真实指令，arm64 切片里会退化成 no-op，
# 那样加载 arm64e 的 macOS 二进制时 `braa` 一执行就 PAC 校验失败。

# 只出 arm64e：如果包里同时有 arm64 切片，iOS 会优先选 arm64（签名对 arm64e
# 不完整时尤其如此），而 arm64 目标下 __has_feature(ptrauth_calls) 为假，
# ptrauth_sign_unauthenticated 退化成 no-op —— 加载 arm64e 的 macOS 二进制
# 时 braa 一执行就 PAC 失败（SIGTRAP / 退出码 -5）。
ARCHS = arm64e
TARGET = iphone:clang:latest:12.2

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------- App
APPLICATION_NAME = MacPad

MacPad_FILES = app/main.m app/loader.c app/shell.c
MacPad_FRAMEWORKS = UIKit Foundation
# Theos 默认走 MRC，而 UI 代码里用了 __weak 和 block 捕获，
# 必须显式开 ARC，否则 "cannot create __weak reference" 直接编译失败。
MacPad_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter \
                -Wno-unused-variable -Wno-unused-function
MacPad_INSTALL_PATH = /Applications
MacPad_CODESIGN_FLAGS = -Sapp/MacPad.entitlements
MacPad_RESOURCE_DIRS = app/Resources

include $(THEOS_MAKE_PATH)/application.mk

# ---------------------------------------------------------------- PlayPad（新增，不动上面的 MacPad）
# iPad 上的 PlayCover：IPA 库 → 图标网格 → 触控点开 → 安装 → 启动。
# 和 MacPad 是同一份 deb 里的两个独立 App，互不依赖：
#   MacPad   = 终端 + 进程内 Mach-O 装载器（跑 macOS 二进制）
#   PlayPad  = UIKit 应用管理台（装 / 启动 iOS 应用）
# 它能装包的前提是设备上有 AppSync Unified，让 installd 放行自签包。
APPLICATION_NAME = PlayPad

PlayPad_FILES = app/playpad/main.m
PlayPad_FRAMEWORKS = UIKit Foundation QuartzCore
# IPA 是 zip，取 Info.plist 与图标要 raw inflate
PlayPad_LIBRARIES = z
PlayPad_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter \
                 -Wno-unused-variable -Wno-unused-function -Wno-objc-method-access
PlayPad_INSTALL_PATH = /Applications
PlayPad_CODESIGN_FLAGS = -Sapp/playpad/PlayPad.entitlements
PlayPad_RESOURCE_DIRS = app/playpad/Resources

include $(THEOS_MAKE_PATH)/application.mk

# ---------------------------------------------------------------- 命令行版
# 同一份 loader.c，只是不经过 UIKit / SpringBoard，可以从 SSH 直接跑。
# 用途：验证装载器本身，以及在设备锁屏、无法启动 GUI 时仍能工作。
TOOL_NAME = macpadcli
macpadcli_FILES = app/cli.c app/loader.c app/shell.c
macpadcli_INSTALL_PATH = /usr/bin
macpadcli_CODESIGN_FLAGS = -Sapp/MacPad.entitlements
macpadcli_CFLAGS = -Wno-deprecated-declarations -Wno-unused-parameter \
                   -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tool.mk

# ---------------------------------------------------------------- PlayPad 的 root 执行器
# App 是 mobile 用户，写不进 /Applications、也调不了 ldid；安装/卸载/启动都由它来干。
TOOL_NAME = playpadctl
playpadctl_FILES = app/playpadctl/main.m
playpadctl_FRAMEWORKS = Foundation
playpadctl_INSTALL_PATH = /usr/bin
playpadctl_CODESIGN_FLAGS = -Sapp/playpad/PlayPad.entitlements
playpadctl_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter \
                    -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tool.mk

# ---------------------------------------------------------------- 系统 dyld 探针
# macpadcli 是进程内装载器，用 dlsym 找符号，会误判 Foundation 的私有符号。
# lctest 换成让**系统 dyld** 去加载，给出真实结论（缺不缺、类注册没注册）。
TOOL_NAME = lctest
lctest_FILES = app/lctest/main.m
lctest_FRAMEWORKS = Foundation
lctest_INSTALL_PATH = /usr/bin
lctest_CODESIGN_FLAGS = -Sapp/playpad/PlayPad.entitlements
lctest_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter \
                -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tool.mk

# ---------------------------------------------------------------- iOS 12 兼容桩库
# iOS 13+ 的 App 会挂上本机不存在的系统库（CoreHaptics / libswiftUniformTypeIdentifiers…）。
# dyld 在 iOS 12.2 上对"image not found"是硬 abort，哪怕那库一次都没调用。
# 这一个 dylib 把它们的符号全导出来；安装时 patch_deps.py 把那些 load command
# 的路径改指到这里，一份桩顶五份。
LIBRARY_NAME = ios12stub
ios12stub_FILES = app/stubs/ios12stub.m app/stubs/pptrace.m
ios12stub_FRAMEWORKS = Foundation
ios12stub_INSTALL_PATH = /usr/lib
ios12stub_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter \
                   -Wno-unused-variable -Wno-unused-function \
                   -Wno-incompatible-pointer-types -Wno-mismatched-parameter-types
# 必须编成 arm64，不能跟着工具链默认的 arm64e 走。
# App Store 分发的 IPA 是 arm64 单切片，App 进程就是 arm64；arm64e 的 dylib 虽然
# 能被 arm64 进程加载，但它的函数指针带 PAC 签名（实测 __mod_init_func 槽位是
# 0x0008000000005cdc 这种），iOS 12.2 的 dyld 做 rebase 时按 "加 slide" 处理，
# 签名被算坏，跳到 pc=0。arm64 没有这层，指针就是裸地址。
ios12stub_ARCHS = arm64

include $(THEOS_MAKE_PATH)/library.mk

# ---------------------------------------------------------------- 注入式探针（调试通道，保留）
TWEAK_NAME = MacPadProbe MacPadLoader

MacPadProbe_FILES = MacPadProbe.xm
MacPadProbe_FRAMEWORKS = Foundation
# syscall(2) 在 SDK 里标了 deprecated，但探针要的就是它。
MacPadProbe_CFLAGS = -Wno-deprecated-declarations

MacPadLoader_FILES = MacPadLoader.xm
MacPadLoader_FRAMEWORKS = Foundation
MacPadLoader_CFLAGS = -Wno-deprecated-declarations -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk

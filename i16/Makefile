# i16 —— 在 iOS 12.2 上提供 iOS 13 / 14 / 15 / 16 的框架 API
#
# 这个工程只做一件事：**用 iOS 12 已经有的 API，实现 iOS 16 才有的 API**。
# 不碰内核、不碰驱动、不需要换系统 —— 全部是用户态的一层实现。
#
# 产出两样东西：
#   i16.app     —— 能力面板。每一项 API 都能在设备上真跑一遍，状态是实测的。
#   i16shim.dylib —— 同一份实现，独立成库，可被别的 App 注入复用。
#
# 目标 12.2 是硬底线：源码里不允许出现 iOS 13+ 的符号名以外的任何依赖。
#
# SDK 写死 12.4 而不是 latest：CI 只装 iPhoneOS12.4.sdk，写 latest 会随环境漂移，
# 换一台机器编出来的二进制就不一样了。部署目标仍是 12.2。
TARGET = iphone:clang:12.4:12.2
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------- 能力面板 App
APPLICATION_NAME = i16

i16_FILES = app/main.m \
            app/ui16.m \
            app/inapp_probe.m \
            shim/i16_core.m \
            shim/i16_color.m \
            shim/i16_menu.m \
            shim/i16_type.m \
            shim/i16_list.m \
            shim/i16_symbol.m

i16_FRAMEWORKS = UIKit Foundation MobileCoreServices ImageIO
i16_CFLAGS = -fobjc-arc -Ishim -Wno-deprecated-declarations -Wno-unused-parameter \
             -Wno-unused-function -Wno-objc-method-access
i16_INSTALL_PATH = /Applications
i16_CODESIGN_FLAGS = -Sapp/i16.entitlements
# 启动图（UILaunchImages 用）。Theos 会把目录内容拷进 bundle 根。
i16_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk

# ---------------------------------------------------------------- 可注入的 shim
# 同一批源文件再编一份 dylib。别的 App 用 insert_dylib / 重签名注入进来，
# 就能在自己的进程里拿到这些 API，不需要知道实现从哪来。
LIBRARY_NAME = i16shim

i16shim_FILES = shim/i16_core.m \
                shim/i16_color.m \
                shim/i16_menu.m \
                shim/i16_type.m \
                shim/i16_list.m \
                shim/i16_symbol.m \
                shim/i16_inject.m

i16shim_FRAMEWORKS = UIKit Foundation MobileCoreServices
i16shim_CFLAGS = -fobjc-arc -Ishim -Wno-deprecated-declarations -Wno-unused-parameter \
                 -Wno-unused-function -Wno-objc-method-access
# 必须 arm64：目标 App 是 App Store 的 arm64 单切片，arm64e 的 dylib 进不去。
i16shim_ARCHS = arm64
i16shim_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk

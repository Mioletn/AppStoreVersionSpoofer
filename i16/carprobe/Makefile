# carprobe —— 独立的命令行探针，单独编成 /usr/bin/carprobe
#
# 为什么不并进主 Makefile：application / library / tool 三种 target 混在一个
# Makefile 里，Theos 的多 target 支持容易在 include 顺序上出问题，而这一轮
# 的目的是「尽快拿到设备上的真实答案」，不值得为省一个目录去冒 CI 失败的风险。
#
# 部署目标与主工程一致：12.2。
TARGET = iphone:clang:12.4:12.2
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = carprobe sfprobe streamprobe

carprobe_FILES = carprobe.m
# 只要 Foundation + CoreGraphics：探针要跑在 SSH 的裸 shell 里，没有 WindowServer。
# 链 UIKit 只会把 GraphicsServices 那一串拖进来；取图到 CGImage 为止就够了，
# 包成 UIImage 是 i16shim 的事，不在探针里做。
carprobe_FRAMEWORKS = Foundation CoreGraphics
carprobe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter
carprobe_INSTALL_PATH = /usr/bin

# sfprobe 要额外链 ImageIO：它把几张符号渲染成 PNG 存到磁盘，
# 这样「光栅化成功」这件事能被人眼看一遍，而不只是靠数字。
sfprobe_FILES = sfprobe.m
sfprobe_FRAMEWORKS = Foundation CoreGraphics ImageIO
sfprobe_CFLAGS = -fobjc-arc -fobjc-weak -Wno-deprecated-declarations -Wno-unused-parameter
# libcompression：要验证 12.2 能不能解 LZFSE，得直接调系统解码器
sfprobe_LDFLAGS = -lcompression
sfprobe_INSTALL_PATH = /usr/bin

# streamprobe：屏幕采集（IOMobileFramebuffer / CARenderServer）+ HID 注入探针。
# 不链 IOSurface：12.4 的 SDK 里它是私有框架，既没有头文件也没有可链接的 stub，
# 所以整组符号走 dlopen/dlsym。少一个链接依赖，也少一类「换台机器编不过」。
streamprobe_FILES = streamprobe.m
streamprobe_FRAMEWORKS = Foundation CoreGraphics
streamprobe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter
streamprobe_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk

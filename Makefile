ARCHS = arm64
# 部署目标 iOS 12.2；现代 Theos 自带 clang 即可编译 arm64（iOS12 不再有 32 位，无 old ABI 问题）
TARGET = iphone:clang:latest:12.2
INSTALL_TARGET_PROCESSES = AppStore appstored

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppStoreVersionSpoofer
AppStoreVersionSpoofer_FILES = Tweak.xm
AppStoreVersionSpoofer_CFLAGS = -fobjc-arc
AppStoreVersionSpoofer_FRAMEWORKS = Foundation

BUNDLE_NAME = AppStoreVersionSpooferPrefs
AppStoreVersionSpooferPrefs_FILES = Preferences/RootListController.m
AppStoreVersionSpooferPrefs_RESOURCE_DIRS = Resources
AppStoreVersionSpooferPrefs_INFO_PLIST_PATH = Resources/Info.plist
AppStoreVersionSpooferPrefs_INSTALL_PATH = /Library/PreferenceBundles
AppStoreVersionSpooferPrefs_FRAMEWORKS = Foundation
# 链接私有 Preferences.framework（SDK 仅含其链接桩，无公开头文件，故源码用前向声明）。
# 运行时 Settings 已加载该框架，符号在宿主进程内解析，不会造成重复加载/闪退。
AppStoreVersionSpooferPrefs_PRIVATE_FRAMEWORKS = Preferences
# 偏好 bundle 强制开启 ARC：直接对 _specifiers 实例变量赋值在 MRC 下会悬垂，
# 开启 ARC 后由编译器自动管理内存，避免设置面板加载时随机崩溃。
AppStoreVersionSpooferPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AppStoreVersionSpoofer.plist$(ECHO_END)

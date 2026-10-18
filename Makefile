ARCHS = arm64
# 部署目标 iOS 12.2
TARGET = iphone:clang:latest:12.2
INSTALL_TARGET_PROCESSES = AppStore appstored

include $(THEOS)/makefiles/common.mk

# ---- 核心 Tweak：注入 App Store / appstored，伪造系统版本 ----
TWEAK_NAME = AppStoreVersionSpoofer
AppStoreVersionSpoofer_FILES = Tweak.xm
AppStoreVersionSpoofer_CFLAGS = -fobjc-arc
AppStoreVersionSpoofer_FRAMEWORKS = Foundation

# ---- 独立配置 App（不接入系统设置，避免偏好 bundle 导致 Settings 闪退）----
APPLICATION_NAME = AppStoreVersionSpooferApp
AppStoreVersionSpooferApp_FILES = AppMain.m AppDelegate.m ViewController.m
AppStoreVersionSpooferApp_FRAMEWORKS = UIKit Foundation
AppStoreVersionSpooferApp_CFLAGS = -fobjc-arc
AppStoreVersionSpooferApp_INFOPLIST_FILE = AppInfo.plist
AppStoreVersionSpooferApp_RESOURCE_FILES = Icon.png Icon@2x.png
AppStoreVersionSpooferApp_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/application.mk

# 强制把 AppInfo.plist 以 Info.plist 之名写入 app bundle（application.mk 的
# INFOPLIST_FILE 变量在部分 Theos 版本未生效，导致 .app 缺 Info.plist 无法启动）。
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app$(ECHO_END)
	$(ECHO_NOTHING)cp AppInfo.plist $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app/Info.plist$(ECHO_END)

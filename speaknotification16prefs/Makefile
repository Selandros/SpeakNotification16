ARCHS = arm64e
TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = Preferences
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

_THEOS_TARGET_LDFLAGS := $(filter-out -multiply_defined suppress,$(_THEOS_TARGET_LDFLAGS))

BUNDLE_NAME = SpeakNotification16Prefs

SpeakNotification16Prefs_FILES = ../SNSharedKeys.m \
    Sources/SNPrefsUtil.m \
    Sources/SNRootListController.m \
    Sources/PerAppListController.m \
    Sources/WifiListController.m \
    Sources/BtListController.m \
    Sources/SNAppListProvider.m \
    Sources/LanguagesListController.m \
    Sources/SNComingListController.m

SpeakNotification16Prefs_INSTALL_PATH = /Library/PreferenceBundles
SpeakNotification16Prefs_FRAMEWORKS = UIKit
SpeakNotification16Prefs_PRIVATE_FRAMEWORKS = Preferences
SpeakNotification16Prefs_RESOURCE_FILES = Resources/Root.plist Resources/Coming.plist

SpeakNotification16Prefs_CFLAGS += -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

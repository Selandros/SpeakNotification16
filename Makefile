ARCHS = arm64e
TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless
# DEBUG = 1
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

_THEOS_TARGET_LDFLAGS := $(filter-out -multiply_defined suppress,$(_THEOS_TARGET_LDFLAGS))

TWEAK_NAME = SpeakNotification16

SpeakNotification16_FILES = \
    Tweak.xm \
    SNLogger.m \
    SNSystemState.m \
    SNAudioState.m \
    SNNetworkState.m \
    SNAppState.m \
    SNDeviceState.m \
    SNMediaControl.m \
    SNEngineAV.m \
    SNEngineRunner.m \
    SNCallMonitor.m \
    SNBurstTracker.m \
    SNStringUtils.m \
    SNPreferences.m \
    SNCancellation.m \
    SNMixPolicy.m \
    SNDuckManager.m \
    SNSharedKeys.m \
    SNSiriGuard.m

SpeakNotification16_FRAMEWORKS = \
    UIKit \
    AVFoundation \
    AudioToolbox \
    NaturalLanguage \
    SystemConfiguration \
    CoreTelephony

SpeakNotification16_PRIVATE_FRAMEWORKS += SpringBoardServices BulletinBoard
SpeakNotification16_CFLAGS += -Wno-deprecated-declarations
Tweak_CFLAGS = -fno-objc-arc
SNStringUtils_CFLAGS = -fno-objc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += speaknotification16prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard || true"

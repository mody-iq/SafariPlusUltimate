export TARGET := iphone:clang:latest:16.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariPlusUltimate

SafariPlusUltimate_FILES = Tweak.xm
SafariPlusUltimate_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SafariPlusUltimate_FRAMEWORKS = UIKit WebKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

export ARCHS = arm64 arm64e
TARGET ?= iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= roothide
export TARGET THEOS_PACKAGE_SCHEME

export DEBUG = 0
export FINALPACKAGE = 1

INSTALL_TARGET_PROCESSES = MobileSlideshow

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PhotosVideoSpeed

PhotosVideoSpeed_FILES = Tweak.xm
PhotosVideoSpeed_CFLAGS = -fobjc-arc
PhotosVideoSpeed_FRAMEWORKS = UIKit AVFoundation CoreMedia QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

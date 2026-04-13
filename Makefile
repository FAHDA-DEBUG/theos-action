ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ONYXElite
ONYXElite_FILES = Tweak.x
ONYXElite_FRAMEWORKS = UIKit Foundation Security CoreLocation Photos AVFoundation AudioToolbox QuartzCore
ONYXElite_LIBRARIES = sqlite3 z
ONYXElite_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

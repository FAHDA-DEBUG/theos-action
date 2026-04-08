ARCHS = arm64 arm64e
TARGET = iphone:clang:14.5:14.5

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TripleLayerGuard
TripleLayerGuard_FILES = Tweak.x
TripleLayerGuard_FRAMEWORKS = UIKit Foundation Security WebKit

include $(THEOS_MAKE_PATH)/tweak.mk

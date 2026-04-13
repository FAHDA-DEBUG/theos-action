ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = Snapchat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ONYXElite

# هنا نحدد ملفات الكود
ONYXElite_FILES = Tweak.x
# إضافة المكتبات اللازمة للحماية والواجهة وقاعدة البيانات
ONYXElite_FRAMEWORKS = UIKit Foundation Security CoreLocation Photos AVFoundation QuartzCore
ONYXElite_LIBRARIES = sqlite3 z
ONYXElite_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Snapchat || true"

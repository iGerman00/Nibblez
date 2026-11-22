TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = YouTubeMusic

ifeq ($(ROOTLESS),1)
THEOS_PACKAGE_SCHEME = rootless
endif

TWEAK_NAME = Nibblez
Nibblez_FILES = $(wildcard Sources/*.m)
Nibblez_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DNIBBLEZ_VERSION=\"0.1.2\"
Nibblez_FRAMEWORKS = UIKit Foundation MediaPlayer UniformTypeIdentifiers
Nibblez_LIBRARIES = z
Nibblez_CFLAGS += -I$(THEOS_PROJECT_DIR)/Sources

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

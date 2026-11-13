ARCHS = arm64 arm64e
TARGET = iphone:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Kira

$(TWEAK_NAME)_FILES = $(shell find Sources \( -name '*.swift' -o -name '*.m' -o -name '*.xm' \))
$(TWEAK_NAME)_SWIFTFLAGS = -ISources/tgapiC/include -Osize
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -ISources/tgapiC/include -ISources/compat -Wno-deprecated-declarations -Os
$(TWEAK_NAME)_LDFLAGS = -Wl,-dead_strip
$(TWEAK_NAME)_FRAMEWORKS = CoreServices AVFoundation Photos QuartzCore
$(TWEAK_NAME)_LIBRARIES = z
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal
$(TWEAK_NAME)_RESOURCE_FILES = Sources/tgapi/Resources

# Copy Kira.bundle manually during the packaging step
after-stage::
	@echo ">>> Copying Kira.bundle into .deb package..."
	@mkdir -p $(THEOS_STAGING_DIR)/Library/Application\ Support/Kira
	@cp -a Kira.bundle $(THEOS_STAGING_DIR)/Library/Application\ Support/Kira

include $(THEOS_MAKE_PATH)/tweak.mk

# Also copy the .dylib into packages/ for direct sideload use
after-package::
	@mkdir -p packages
	@cp -f $(THEOS_OBJ_DIR)/Kira.dylib packages/Kira.dylib
	@echo ">>> .dylib copied to packages/Kira.dylib"

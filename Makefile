ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

# Plain library (no CydiaSubstrate/ElleKit dependency) so it can be injected into an IPA.
LIBRARY_NAME = YTGlass

YTGlass_FILES = Sources/TabBarAutoHide.m Sources/SearchButton.m Sources/HideTopBar.m Sources/PlayerGlass.m Sources/HomeSpacing.m Sources/TabAnimation.m Sources/MenuSettings.m Sources/YTPlusFixes.m Sources/Settings.m
YTGlass_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -DYTG_VERSION=\"$(shell grep '^Version:' control | cut -d' ' -f2)\"
YTGlass_FRAMEWORKS = Foundation UIKit QuartzCore
YTGlass_LDFLAGS = -Wl,-install_name,@rpath/YTGlass.dylib
YTGlass_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

after-all::
	@mkdir -p "$(THEOS_PROJECT_DIR)/dist"
	@cp "$(THEOS_OBJ_DIR)/YTGlass.dylib" "$(THEOS_PROJECT_DIR)/dist/YTGlass.dylib"

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	@cp "$(THEOS_PROJECT_DIR)/YTGlass.plist" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/YTGlass.plist"

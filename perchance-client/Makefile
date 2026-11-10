TARGET := iphone:clang:12.4:12.0
ARCHS := arm64

# Исходники транспайлера (single source of truth) живут в ../perchance-ios12/lib.
P := ../perchance-ios12/lib

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Perchance

Perchance_FILES := $(wildcard Sources/*.m)

Perchance_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
Perchance_CFLAGS += -Wno-unused-function -Wno-sign-compare -Wno-unknown-warning-option
Perchance_CFLAGS += -Wno-unused-variable -Wno-missing-braces -Wno-format-nonliteral

Perchance_FRAMEWORKS := UIKit Foundation WebKit JavaScriptCore Security

Perchance_INSTALL_PATH = /Applications
Perchance_RESOURCE_DIRS = Resources
Perchance_CODESIGN_FLAGS = -S

include $(THEOS_MAKE_PATH)/application.mk

# ---------------------------------------------------------------------------
# Копируем веб-ядро в Resources/web при сборке — один источник правды,
# поэтому правки в perchance-ios12/lib автоматически попадают в приложение.
# ---------------------------------------------------------------------------
before-all::
	@mkdir -p Resources/web
	@cp -f $(P)/web/transform-web.js Resources/web/transform-web.js
	@cp -f $(P)/polyfills.js          Resources/web/polyfills.js
	@cp -f $(P)/legacy.js             Resources/web/legacy.js
	@cp -f $(P)/babel.min.js          Resources/web/babel.min.js
	@echo "[Perchance] web core copied: $$(ls Resources/web | tr '\n' ' ')"

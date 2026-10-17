#!/bin/bash
# Builds ClaudeBridger.app from the SwiftPM executable.
#
# The result is an ad-hoc signed bundle: it runs on this machine and it is what CI can produce
# without a developer certificate. It is not notarised, so Gatekeeper will quarantine it if the
# .app is downloaded rather than built locally — the README says how to clear that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/ClaudeBridger.app"
APP_NAME="ClaudeBridger"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo "0.0.0")"

# The bundle identifier must be in a namespace this project owns. It is what macOS keys the app's
# preferences, its ad-hoc signature and its Launch Services registration on.
BUNDLE_ID="com.claudebridger.app"

# Every recognised iconset filename. The icon ships at the repo root and is copied, not generated:
# SwiftPM has no notion of a macOS app icon, so the bundle assembly is the only place it can be
# attached. A missing file is a warning rather than an error so the app still builds from a
# checkout that excluded the artwork.
ICON_SOURCE="$ROOT/ClaudeBridger.icns"

echo "==> Building release binary"
# Named product rather than the whole package: the package also holds ScreenshotRenderer, which
# is a build-time tool for the README images and has no business in a release build.
swift build -c release --package-path "$ROOT" --product "$APP_NAME"

BINARY="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$APP_NAME"
if [ ! -x "$BINARY" ]; then
    echo "error: expected executable not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# PkgInfo: the four-character type/creator pair. Still read by some older tooling, and its absence
# is one of the small things that makes a hand-built bundle look unfinished.
printf "APPL????" > "$APP/Contents/PkgInfo"

if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$APP/Contents/Resources/$APP_NAME.icns"
    echo "    icon: $APP_NAME.icns ($(du -h "$ICON_SOURCE" | cut -f1))"
else
    echo "    warning: $ICON_SOURCE not found; the app will use the generic icon"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
</dict>
</plist>
PLIST

# Read the version back out of the assembled bundle so a mistake in the heredoc above cannot ship
# silently as a wrong version.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$PLIST_VERSION" != "$VERSION" ]; then
    echo "error: bundle version $PLIST_VERSION does not match VERSION $VERSION" >&2
    exit 1
fi
PLIST_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
if [ ! -f "$APP/Contents/Resources/$PLIST_ICON.icns" ]; then
    echo "error: CFBundleIconFile names $PLIST_ICON but that resource is not in the bundle" >&2
    exit 1
fi

# Ad-hoc signature. Keeps the bundle launchable locally; it is not a substitute for a real
# Developer ID signature and does not satisfy Gatekeeper for downloaded copies.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "warning: ad-hoc codesign failed; the app may still run locally"

echo "==> Done: $APP (v$PLIST_VERSION, $BUNDLE_ID)"

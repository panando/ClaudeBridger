#!/bin/bash
# Builds build/ClaudeBridger-<version>.dmg containing the .app and an /Applications symlink.
#
# Two things in here are deliberate:
#
# 1. It never uses `hdiutil create -srcfolder`. That needs disk arbitration to mount a writable
#    scratch image, which fails in restricted environments and in CI with "operation not
#    permitted". Both paths below write the image without needing a writable mount, so this works
#    anywhere the app can be built.
#
# 2. It prefers `diskutil image`, which replaced `hdiutil convert`/`attach` (macOS now prints
#    deprecation warnings for those), and falls back to `hdiutil` because the app supports
#    macOS 14, where `diskutil image` may not exist yet.
#
# The image is ad-hoc signed, not notarised. Gatekeeper will quarantine it on a machine that
# downloaded it, and the README documents the two ways past that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_NAME="ClaudeBridger"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
VOLUME_NAME="$APP_NAME"
STAGING="$BUILD_DIR/dmg-staging"
PLAIN_DMG="$BUILD_DIR/dmg-uncompressed.dmg"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
MOUNT_POINT="$BUILD_DIR/dmg-verify"

# `diskutil image` arrived after macOS 14, so its presence is what decides the path.
USE_MODERN=0
if diskutil image create from --help >/dev/null 2>&1; then
    USE_MODERN=1
fi

cleanup() {
    # Detach if a verification failure left the image mounted, so a failed run does not leave a
    # volume behind that blocks the next one.
    if [ -d "$MOUNT_POINT" ]; then
        if [ "$USE_MODERN" = "1" ]; then
            diskutil unmount "$MOUNT_POINT" >/dev/null 2>&1 || true
        else
            hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
        fi
    fi
    rm -rf "$STAGING" "$PLAIN_DMG" "$MOUNT_POINT"
}
trap cleanup EXIT

if [ ! -d "$APP" ]; then
    echo "error: $APP not found. Run scripts/build-app.sh first." >&2
    exit 1
fi

# The version in the bundle is the one users see in Get Info, so a mismatch between it and the
# filename would be a lie in one of the two places.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$APP_VERSION" != "$VERSION" ]; then
    echo "error: app bundle is $APP_VERSION but VERSION is $VERSION. Rebuild the app." >&2
    exit 1
fi

echo "==> Staging $APP_NAME $VERSION"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
# The drag-to-install target. A symlink rather than a copy, which is what keeps the DMG small.
ln -s /Applications "$STAGING/Applications"

echo "==> Creating disk image"
rm -f "$DMG_PATH"
if [ "$USE_MODERN" = "1" ]; then
    diskutil image create from --format UDZO --volumeName "$VOLUME_NAME" "$STAGING" "$DMG_PATH" >/dev/null
else
    hdiutil makehybrid -hfs -hfs-volume-name "$VOLUME_NAME" -ov -o "$PLAIN_DMG" "$STAGING" >/dev/null
    hdiutil convert "$PLAIN_DMG" -format UDZO -ov -o "$DMG_PATH" >/dev/null
fi

codesign --force --sign - "$DMG_PATH" >/dev/null 2>&1 || \
    echo "warning: ad-hoc codesign of the DMG failed"

# Verify by mounting it back. Compressing an image can fail in ways that still produce a file of
# roughly the right size, so the only check worth making is whether the app inside is intact.
echo "==> Verifying"
mkdir -p "$MOUNT_POINT"
if [ "$USE_MODERN" = "1" ]; then
    diskutil image attach --readOnly --mountPoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
else
    hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
fi

MOUNTED_APP="$MOUNT_POINT/$APP_NAME.app"
if [ ! -x "$MOUNTED_APP/Contents/MacOS/$APP_NAME" ]; then
    echo "error: the mounted image has no executable at $APP_NAME.app/Contents/MacOS/$APP_NAME" >&2
    exit 1
fi
if [ ! -L "$MOUNT_POINT/Applications" ]; then
    echo "error: the mounted image has no /Applications symlink" >&2
    exit 1
fi
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
if [ "$MOUNTED_VERSION" != "$VERSION" ]; then
    echo "error: the app inside the image is $MOUNTED_VERSION, expected $VERSION" >&2
    exit 1
fi
ARCHS="$(lipo -archs "$MOUNTED_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)"
if [ -z "$ARCHS" ]; then
    echo "error: could not read the architecture of the bundled executable" >&2
    exit 1
fi

if [ "$USE_MODERN" = "1" ]; then
    diskutil unmount "$MOUNT_POINT" >/dev/null
else
    hdiutil detach "$MOUNT_POINT" -quiet
fi
rmdir "$MOUNT_POINT"

echo "==> Done: $DMG_PATH"
echo "    version $MOUNTED_VERSION, arch $ARCHS, $(du -h "$DMG_PATH" | cut -f1)"

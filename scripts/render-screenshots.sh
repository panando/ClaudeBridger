#!/usr/bin/env bash
#
# Renders the README screenshots.
#
# Uses Sources/ScreenshotRenderer, which hosts the real views in an offscreen NSWindow. That is
# deliberately not `screencapture` (needs the Screen Recording permission) and not SwiftUI's
# `ImageRenderer` (refuses NavigationSplitView and List, returning a "not supported" placeholder).
#
# Everything happens against a throwaway CLAUDE_CONFIG_DIR, so your own ~/.claude is never read
# or written.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO/docs/images}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claudebridger-shots.XXXXXX")"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> building renderer"
swift build --package-path "$REPO" --product ScreenshotRenderer -c release >/dev/null

BIN="$(swift build --package-path "$REPO" --product ScreenshotRenderer -c release --show-bin-path)/ScreenshotRenderer"

mkdir -p "$OUT"
echo "==> rendering into $OUT"
# CLAUDE_CONFIG_DIR must point at an empty directory: the renderer seeds it, and seeding a
# directory that already holds a real configuration would overwrite it.
CLAUDE_CONFIG_DIR="$WORK/config" "$BIN" "$OUT"

echo "==> done"

#!/bin/zsh
# Builds TabStash.app into ./build without Xcode (Command Line Tools are enough).
#
#   ./build.sh                            # signs with "TabStash Dev" if that identity exists, else ad-hoc
#   SIGN_IDENTITY="My Cert" ./build.sh    # sign with another certificate
#
# A stable signing identity matters: macOS ties the Accessibility grant to the
# signature, and ad-hoc signatures change on every build. Run ./make-cert.sh once
# to create the "TabStash Dev" identity.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TabStash"
BUILD_DIR="build"
APP="$BUILD_DIR/TabStash.app"
CONTENTS="$APP/Contents"
DEFAULT_IDENTITY="TabStash Dev"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$DEFAULT_IDENTITY\""; then
    SIGN_IDENTITY="$DEFAULT_IDENTITY"
  else
    SIGN_IDENTITY="-"
    echo "note: signing ad-hoc; run ./make-cert.sh once so the Accessibility grant survives rebuilds"
  fi
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework ServiceManagement \
  Sources/*.swift \
  -o "$CONTENTS/MacOS/$APP_NAME"

cp Info.plist "$CONTENTS/Info.plist"

# App icon: rendered from the same glyph as the menu bar icon.
ICONSET="$BUILD_DIR/AppIcon.iconset"
if [[ ! -f "$BUILD_DIR/AppIcon.icns" || Tools/MakeIcon/main.swift -nt "$BUILD_DIR/AppIcon.icns" || Sources/StatusIcon.swift -nt "$BUILD_DIR/AppIcon.icns" ]]; then
  swiftc -O -target arm64-apple-macos13.0 -framework AppKit Tools/MakeIcon/main.swift Sources/StatusIcon.swift -o "$BUILD_DIR/MakeIcon"
  rm -rf "$ICONSET"
  "$BUILD_DIR/MakeIcon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
fi
cp "$BUILD_DIR/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
echo "Built: $APP (signed with: $SIGN_IDENTITY)"

#!/bin/sh
# Build in release mode and assemble dist/Quotaback.app
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP=dist/Quotaback.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Quotaback"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Quotaback"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.otiai10.quotaback</string>
    <key>CFBundleName</key><string>Quotaback</string>
    <key>CFBundleExecutable</key><string>Quotaback</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Signing (SMAppService login item registration requires a signature). Uses SIGN_IDENTITY, else the
# "Developer ID Application" identity in the keychain (hardened runtime + secure timestamp, as notarization
# requires), else ad-hoc. SIGN_IDENTITY=- forces ad-hoc
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -n 1)}"
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
    echo "signed ad-hoc"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict "$APP"
    echo "signed with $IDENTITY"
fi
echo "built $APP"

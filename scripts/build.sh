#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Usage Notifier.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Remove the obsolete helper when rebuilding an existing app bundle.
rm -f "$APP/Contents/MacOS/usage-helper"
xcrun swiftc -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/UsageNotifier" \
    -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework SwiftUI -framework Security -framework LocalAuthentication -O
cp Resources/Info.plist "$APP/Contents/Info.plist"
xcrun swift scripts/make-icon.swift "$PWD/build"
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

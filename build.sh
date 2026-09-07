#!/bin/bash
# Builds Laqta.app and installs it to the Desktop.
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Desktop/Laqta.app"

cd "$SRC_DIR"
swiftc -O main.swift -o Laqta

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Laqta "$APP/Contents/MacOS/Laqta"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Same stable local identity as Naqla, so permission grants survive rebuilds.
codesign --force --sign "Omar Local Code Signing" --timestamp=none "$APP"

echo "built $APP"

#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
APP_VERSION=$(tr -d '\n' < "$PROJECT_DIR/VERSION")
BUILD_NUMBER=$(tr -d '\n' < "$PROJECT_DIR/BUILD")
[[ "$APP_VERSION" =~ '^[0-9]+\.[0-9]{2}$' && "$BUILD_NUMBER" =~ '^[0-9]+$' ]] || exit 1
STAGING=$(mktemp -d /private/tmp/gaozhengli-build.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/搞整理.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK=$(xcrun --sdk macosx --show-sdk-path)
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
xcrun swiftc -swift-version 5 -Xfrontend -disable-sandbox -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$STAGING/cache" \
  "$STAGING"/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework CryptoKit -framework Security -framework CoreServices -lsqlite3 \
  -o "$APP/Contents/MacOS/GaoZhengLi"
ditto "$PROJECT_DIR/Resources" "$APP/Contents/Resources"
cp "$PROJECT_DIR/使用说明.txt" "$PROJECT_DIR/LICENSE" "$APP/Contents/Resources/"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
python3 "$PROJECT_DIR/Scripts/make_plist.py" "$APP/Contents/Info.plist" "$APP_VERSION" "$BUILD_NUMBER"
plutil -lint "$APP/Contents/Info.plist"
SIGN_IDENTITY=${GAOZHENGLI_SIGN_IDENTITY:--}
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --identifier com.gaoseries.GaoZhengLi "$APP"
codesign --verify --deep --strict "$APP"
if [[ "${1:-}" == '--app-only' ]]; then
  [[ $# == 2 && "$2" == /* && "$2" == *.app && ! -e "$2" ]] || exit 2
  ditto "$APP" "$2"; print "APP=$2"; exit 0
fi
mkdir -p "$PROJECT_DIR/dist" "$STAGING/disk"
ditto "$APP" "$STAGING/disk/搞整理.app"
ln -s /Applications "$STAGING/disk/Applications"
cp "$PROJECT_DIR/使用说明.txt" "$STAGING/disk/使用说明.txt"
hdiutil create -quiet -volname "搞整理 V$APP_VERSION" -srcfolder "$STAGING/disk" -format UDZO "$STAGING/GaoZhengLi-$APP_VERSION.dmg"
hdiutil verify -quiet "$STAGING/GaoZhengLi-$APP_VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/GaoZhengLi-$APP_VERSION-macOS.zip"
ditto "$APP" "$PROJECT_DIR/搞整理.app"
mv "$STAGING/GaoZhengLi-$APP_VERSION.dmg" "$PROJECT_DIR/dist/GaoZhengLi-$APP_VERSION.dmg"
mv "$STAGING/GaoZhengLi-$APP_VERSION-macOS.zip" "$PROJECT_DIR/dist/GaoZhengLi-$APP_VERSION-macOS.zip"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "GaoZhengLi-$APP_VERSION.dmg" "GaoZhengLi-$APP_VERSION-macOS.zip" > SHA256SUMS)
print "构建完成 V$APP_VERSION / $BUILD_NUMBER；未启动应用。"

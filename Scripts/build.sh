#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
APP_VERSION=$(tr -d '\n' < "$PROJECT_DIR/VERSION")
BUILD_NUMBER=$(tr -d '\n' < "$PROJECT_DIR/BUILD")
[[ "$APP_VERSION" =~ '^[0-9]+\.[0-9]{2}$' && "$BUILD_NUMBER" =~ '^[0-9]+$' ]] || exit 1
if [[ $# != 0 ]]; then
  [[ $# == 2 && "$1" == '--app-only' ]] || exit 2
  python3 - "$2" <<'PY'
import os, pathlib, stat, sys
p = pathlib.Path(sys.argv[1])
containers = [q for q in p.parents if q.name.endswith('.noindex')]
if not p.is_absolute() or p.suffix != '.app' or os.path.lexists(p) or not p.parent.is_dir() or p.resolve() != p or not containers:
    raise SystemExit('--app-only requires a nonexistent absolute .app inside a private .noindex container')
info = containers[0].stat()
if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
    raise SystemExit('--app-only .noindex container must be private (0700) and owned by this user')
PY
fi
STAGING_ROOT=$(mktemp -d /private/tmp/gaozhengli-build.XXXXXX)
STAGING="$STAGING_ROOT/build.noindex"
mkdir -m 700 "$STAGING"
trap 'rm -rf "$STAGING_ROOT"' EXIT
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
  python3 - "$PROJECT_DIR/Scripts" "$APP" "$2" <<'PY'
import pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import install
app, output = map(pathlib.Path, sys.argv[2:])
install.verified_copy(app, output)
if install.verify_app(output) != install.verify_app(app):
    raise RuntimeError('App-only copy Info.plist mismatch')
PY
  print "APP=$2"; exit 0
fi
mkdir -p "$PROJECT_DIR/dist" "$STAGING/disk"
ditto "$APP" "$STAGING/disk/搞整理.app"
ln -s /Applications "$STAGING/disk/Applications"
cp "$PROJECT_DIR/使用说明.txt" "$STAGING/disk/使用说明.txt"
hdiutil create -quiet -volname "搞整理 V$APP_VERSION" -srcfolder "$STAGING/disk" -format UDZO "$STAGING/GaoZhengLi-$APP_VERSION.dmg"
hdiutil verify -quiet "$STAGING/GaoZhengLi-$APP_VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/GaoZhengLi-$APP_VERSION-macOS.zip"
# Verify a complete ZIP restore before the temporary expanded app is removed.
python3 - "$PROJECT_DIR/Scripts" "$APP" "$STAGING/GaoZhengLi-$APP_VERSION-macOS.zip" <<'PY'
import pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import install
app, archive = map(pathlib.Path, sys.argv[2:])
install.verify_archive(archive, app.name, install.inventory(app), install.verify_app(app))
PY
mv "$STAGING/GaoZhengLi-$APP_VERSION.dmg" "$PROJECT_DIR/dist/GaoZhengLi-$APP_VERSION.dmg"
mv "$STAGING/GaoZhengLi-$APP_VERSION-macOS.zip" "$PROJECT_DIR/dist/GaoZhengLi-$APP_VERSION-macOS.zip"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "GaoZhengLi-$APP_VERSION.dmg" "GaoZhengLi-$APP_VERSION-macOS.zip" > SHA256SUMS)
print "构建完成 V$APP_VERSION / $BUILD_NUMBER；未启动应用。"

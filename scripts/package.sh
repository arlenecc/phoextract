#!/bin/bash
# 打包正式分发包：Release 构建 → 应用图标 → 组装 .app → ad-hoc 签名 → 拖拽安装 DMG
# 用法: ./scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PhotoExtractor"
DISPLAY_NAME="图片视频提取工具"
BUNDLE_ID="com.phoextract.app"
VERSION="1.0.0"
BUILD_DIR="build"
DIST_DIR="dist"
APP="$BUILD_DIR/$APP_NAME.app"
VOL_NAME="$APP_NAME $VERSION"

echo "==> 1/6 Release 构建"
swift build -c release

echo "==> 2/6 生成应用图标"
mkdir -p "$BUILD_DIR"
swift scripts/make_icon.swift "$BUILD_DIR/AppIcon.png"
mkdir -p "$BUILD_DIR/AppIcon.iconset"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  size="${spec%%:*}"; name="${spec#*:}"
  sips -z "$size" "$size" "$BUILD_DIR/AppIcon.png" \
       --out "$BUILD_DIR/AppIcon.iconset/$name.png" >/dev/null
done
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"

echo "==> 3/6 组装 $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> 4/6 ad-hoc 代码签名"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> 5/6 制作 DMG（可写中间镜像，用于排版）"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
RW_DMG="$BUILD_DIR/$APP_NAME-rw.dmg"
rm -f "$RW_DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -format UDRW -ov "$RW_DMG" >/dev/null

# 挂载并排版图标（应用居左、Applications 居右）；Finder 自动化失败不阻塞打包
hdiutil attach "$RW_DMG" >/dev/null
osascript <<'AS' || echo "（提示）Finder 排版不可用，跳过图标定位"
tell application "Finder"
	tell disk "PhotoExtractor 1.0.0"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 160, 820, 460}
		set viewOptions to icon view options of container window
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to 128
		set position of item "PhotoExtractor.app" of container window to {170, 150}
		set position of item "Applications" of container window to {450, 150}
		close
		open
		update without registering applications
	end tell
end tell
AS
hdiutil detach "/Volumes/$VOL_NAME" >/dev/null

echo "==> 6/6 压缩转换 DMG"
mkdir -p "$DIST_DIR"
FINAL_DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -format UDZO -o "$FINAL_DMG" >/dev/null
hdiutil verify "$FINAL_DMG" >/dev/null && echo "DMG 校验通过"

echo "完成: $FINAL_DMG"

#!/bin/bash
set -e
cd "$(dirname "$0")"

PROJ="$PWD"
VERSION=$(grep 'static let marketing' "$PROJ/Sources/FinderExplorer/AppVersion.swift" | sed 's/.*"\(.*\)"/\1/')
BUILD_NUM=$(grep 'static let build' "$PROJ/Sources/FinderExplorer/AppVersion.swift" | sed 's/.*"\(.*\)"/\1/')
OUT="$PROJ/build"
APP="$OUT/FinderExplorer.app"
STAGE="$OUT/.dmg_stage"
mkdir -p "$OUT"

write_plist() {
cat > "$1" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FinderExplorer</string>
    <key>CFBundleIdentifier</key>
    <string>com.tyhoo.finderexplorer</string>
    <key>CFBundleName</key>
    <string>FinderExplorer</string>
    <key>CFBundleDisplayName</key>
    <string>FinderExplorer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUM}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
}

# 组装 FinderExplorer.app；给 SUFFIX 时打包成发布用 dmg（内含 Applications 快捷方式）
pack() {
    local BIN=$1 SUFFIX=$2
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    mkdir -p "$APP/Contents/Resources"
    cp "$BIN" "$APP/Contents/MacOS/"
    cp "$PROJ/AppIcon.icns" "$APP/Contents/Resources/"
    write_plist "$APP/Contents/Info.plist"

    if [ -n "$SUFFIX" ]; then
        local DMG="$OUT/FinderExplorer_${VERSION}-${SUFFIX}.dmg"
        rm -rf "$STAGE" "$DMG"
        mkdir -p "$STAGE"
        ditto "$APP" "$STAGE/FinderExplorer.app"
        ln -s /Applications "$STAGE/Applications"
        hdiutil create -volname "FinderExplorer" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
        rm -rf "$STAGE"
        echo "  → FinderExplorer_${VERSION}-${SUFFIX}.dmg"
    fi
}

# 清理旧产物（build/ 为新目录，仓库根目录的残留一并清掉）
rm -rf "$OUT"/FinderExplorer_*.dmg "$OUT"/FinderExplorer_*.zip "$APP" "$STAGE"
rm -rf "$PROJ"/FinderExplorer_*.dmg "$PROJ"/FinderExplorer_*.zip "$PROJ"/FinderExplorer.app "$PROJ"/FinderExplorer-*.app "$PROJ"/.dmg_stage

echo "=== 构建 x86_64 ==="
swift build -c release --disable-sandbox --arch x86_64

echo "=== 构建 arm64 ==="
swift build -c release --disable-sandbox --arch arm64

echo "=== 构建 Universal ==="
swift build -c release --disable-sandbox --arch arm64 --arch x86_64

echo ""
echo "=== 打包 ==="
pack ".build/x86_64-apple-macosx/release/FinderExplorer" amd64
pack ".build/arm64-apple-macosx/release/FinderExplorer" arm64
pack ".build/apple/Products/Release/FinderExplorer" universal

# 本地保留一份 universal 的 FinderExplorer.app 供直接运行
pack ".build/apple/Products/Release/FinderExplorer" ""

echo ""
echo "=== 全部完成 ==="
echo "发布 dmg（上传 Releases）："
echo "  build/FinderExplorer_${VERSION}-amd64.dmg"
echo "  build/FinderExplorer_${VERSION}-arm64.dmg"
echo "  build/FinderExplorer_${VERSION}-universal.dmg"
echo "本地运行：$APP"

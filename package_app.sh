#!/bin/bash
set -e
cd "$(dirname "$0")"

# CLT 工具链缺 SwiftUIMacros 插件（macOS 27 SDK），构建统一走完整 Xcode
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

PROJ="$PWD"
VERSION=$(grep 'static let marketing' "$PROJ/Sources/BitXplore/AppVersion.swift" | sed 's/.*"\(.*\)"/\1/')
BUILD_NUM=$(grep 'static let build' "$PROJ/Sources/BitXplore/AppVersion.swift" | sed 's/.*"\(.*\)"/\1/')
OUT="$PROJ/build"
APP="$OUT/BitXplore.app"
STAGE="$OUT/.dmg_stage"
mkdir -p "$OUT"

write_plist() {
cat > "$1" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BitXplore</string>
    <key>CFBundleIdentifier</key>
    <string>top.struct.bitxplore</string>
    <key>CFBundleName</key>
    <string>BitXplore</string>
    <key>CFBundleDisplayName</key>
    <string>BitXplore</string>
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
    <string>27.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
}

# 组装 BitXplore.app；给 SUFFIX 时打包成发布用 dmg（内含 Applications 快捷方式）
pack() {
    local BIN=$1 SUFFIX=$2
    local BIN_DIR
    BIN_DIR="$(dirname "$BIN")"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    mkdir -p "$APP/Contents/Resources"
    cp "$BIN" "$APP/Contents/MacOS/"
    cp "$PROJ/AppIcon.icns" "$APP/Contents/Resources/"
    if [ -d "$BIN_DIR/BitXplore_BitXplore.bundle" ]; then
        cp -R "$BIN_DIR/BitXplore_BitXplore.bundle" "$APP/Contents/Resources/"
    fi
    write_plist "$APP/Contents/Info.plist"

    if [ -n "$SUFFIX" ]; then
        local DMG="$OUT/BitXplore_${VERSION}-${SUFFIX}.dmg"
        rm -rf "$STAGE" "$DMG"
        mkdir -p "$STAGE"
        ditto "$APP" "$STAGE/BitXplore.app"
        ln -s /Applications "$STAGE/Applications"
        hdiutil create -volname "BitXplore" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
        rm -rf "$STAGE"
        echo "  → BitXplore_${VERSION}-${SUFFIX}.dmg"
    fi
}

# 清理旧产物（build/ 为新目录，仓库根目录的残留一并清掉）
rm -rf "$OUT"/BitXplore_*.dmg "$OUT"/BitXplore_*.zip "$APP" "$STAGE"
rm -rf "$PROJ"/BitXplore_*.dmg "$PROJ"/BitXplore_*.zip "$PROJ"/BitXplore.app "$PROJ"/BitXplore-*.app "$PROJ"/.dmg_stage

# Swift 6.4 SwiftBuild 统一输出到 .build/out/Products/Release，每个架构构建后立即打包避免被后续架构覆盖
build_and_pack() {
    local LABEL=$1 SUFFIX=$2
    shift 2
    echo "=== 构建并打包 ${LABEL} ==="
    swift build -c release --disable-sandbox "$@"
    local BIN_DIR
    BIN_DIR=$(swift build -c release --disable-sandbox "$@" --show-bin-path)
    pack "$BIN_DIR/BitXplore" "$SUFFIX"
}

build_and_pack "x86_64" amd64 --arch x86_64
build_and_pack "arm64" arm64 --arch arm64
build_and_pack "Universal" universal --arch arm64 --arch x86_64

echo ""
echo "=== 全部完成 ==="
echo "发布 dmg（上传 Releases）："
echo "  build/BitXplore_${VERSION}-amd64.dmg"
echo "  build/BitXplore_${VERSION}-arm64.dmg"
echo "  build/BitXplore_${VERSION}-universal.dmg"
echo "本地运行：$APP"

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
BG_DIR="$OUT/.dmg_background"
RW_DMG="$OUT/.dmg_rw.dmg"
mkdir -p "$OUT"

write_plist() {
cat > "$1" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
    </array>
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

# dmg 安装窗口的背景图（1x + 2x 合成一个 tiff，Finder 按屏幕自动取用）
make_background() {
    swift "$PROJ/generate_dmg_background.swift" "$BG_DIR" >/dev/null
    tiffutil -cathidpicheck "$BG_DIR/background.png" "$BG_DIR/background@2x.png" -out "$BG_DIR/background.tiff" >/dev/null 2>&1
}

# 用 Finder 设置安装窗口：大小、隐藏工具栏、背景、图标位置。
# 尺寸与坐标须与 generate_dmg_background.swift 一致（内容区 660×400，标题栏另算 28）
layout_window() {
    osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
    set d to (POSIX file "$1" as alias)
    open d
    set w to container window of d
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 860, 548}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 112
    set text size of o to 13
    set background picture of o to (POSIX file "$1/.background/background.tiff" as alias)
    set position of item "BitXplore.app" of d to {170, 190}
    set position of item "Applications" of d to {490, 190}
    update d without registering applications
    delay 1
    close w
end tell
APPLESCRIPT
}

# 组装 BitXplore.app；给 SUFFIX 时打包成发布用 dmg（内含 Applications 快捷方式、背景与图标布局）
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
        mkdir -p "$STAGE/.background"
        cp "$BG_DIR/background.tiff" "$STAGE/.background/"

        # 先做可写镜像让 Finder 写入 .DS_Store（多留 20MB 余量），再压缩成只读 UDZO
        local SIZE_MB
        SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
        rm -f "$RW_DMG"
        hdiutil create -volname "BitXplore" -srcfolder "$STAGE" -size "${SIZE_MB}m" -ov -format UDRW "$RW_DMG" >/dev/null
        rm -rf "$STAGE"
        # Finder 按卷名找卷：必须恰好挂在 /Volumes/BitXplore，否则布局会写到别的同名卷上（见 eject_old_volumes）
        local MOUNT
        MOUNT=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*$')
        if [ "$MOUNT" != "/Volumes/BitXplore" ]; then
            hdiutil detach "$MOUNT" -quiet
            echo "错误：可写镜像挂到了 $MOUNT，说明还有别的 BitXplore 卷，请先推出" >&2
            exit 1
        fi
        SetFile -a V "$MOUNT/.background"
        layout_window "$MOUNT" || echo "  ! Finder 布局失败（需在「系统设置 › 隐私与安全性 › 自动化」允许终端控制 Finder），dmg 可用但无背景"
        # Finder 关窗后才异步写 .DS_Store（布局就存在这里）；不等它写完就卸载，dmg 里就没有布局
        local i
        for i in $(seq 30); do
            [ -f "$MOUNT/.DS_Store" ] && break
            sleep 0.5
        done
        [ -f "$MOUNT/.DS_Store" ] || echo "  ! Finder 没有写入 .DS_Store，dmg 打开后不会有背景与布局"
        sleep 1  # 文件出现后再给 Finder 一点时间写完
        # 卷图标须在布局之后放：Finder 布局时会删掉 .VolumeIcon.icns 并清掉自定义图标标记
        cp "$PROJ/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
        SetFile -a V "$MOUNT/.VolumeIcon.icns"
        SetFile -a C "$MOUNT"
        sync
        hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
        hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
        rm -f "$RW_DMG"
        echo "  → BitXplore_${VERSION}-${SUFFIX}.dmg"
    fi
}

# AppleScript 里的卷按名字解析，同名卷不止一个时会改到错的那个（实际改的是旧 dmg，新 dmg 没有布局）。
# 先推出镜像文件在 build/ 里的旧卷（马上会被覆盖），还剩同名卷就停下
eject_old_volumes() {
    local dev
    for dev in $(hdiutil info | awk -v out="$OUT/" '/^image-path/ { keep = index($0, out) > 0 } /^\/dev\/disk[0-9]+\t/ && keep { print $1 }'); do
        hdiutil detach "$dev" -quiet || hdiutil detach "$dev" -force -quiet || true
    done
    if ls -d /Volumes/BitXplore* >/dev/null 2>&1; then
        echo "错误：以下 BitXplore 卷仍挂载着，dmg 布局会写错卷，请在 Finder 中推出后重试：" >&2
        ls -d /Volumes/BitXplore* >&2
        exit 1
    fi
}

eject_old_volumes

# 清理旧产物（build/ 为新目录，仓库根目录的残留一并清掉）
rm -rf "$OUT"/BitXplore_*.dmg "$OUT"/BitXplore_*.zip "$APP" "$STAGE" "$BG_DIR" "$RW_DMG"
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

make_background
build_and_pack "x86_64" amd64 --arch x86_64
build_and_pack "arm64" arm64 --arch arm64
build_and_pack "Universal" universal --arch arm64 --arch x86_64
rm -rf "$BG_DIR"

echo ""
echo "=== 全部完成 ==="
echo "发布 dmg（上传 Releases）："
echo "  build/BitXplore_${VERSION}-amd64.dmg"
echo "  build/BitXplore_${VERSION}-arm64.dmg"
echo "  build/BitXplore_${VERSION}-universal.dmg"
echo "本地运行：$APP"

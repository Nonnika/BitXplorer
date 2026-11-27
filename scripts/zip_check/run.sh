#!/bin/bash
# 构造测试压缩包（含中文名、无目录条目、stored/deflate 两种方式），编译并运行 ZipArchive 自检
set -e
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
mkdir -p "$T/src/中文目录/深层"
echo hello > "$T/src/a.txt"
echo secret > "$T/src/.hidden"
yes "可压缩的重复内容" | head -2000 > "$T/src/中文目录/深层/b.txt"
(cd "$T/src" && zip -qrD -9 "$T/deflate.zip" . && zip -qrD -0 "$T/stored.zip" .)
head -c 100 "$T/deflate.zip" > "$T/broken.zip"
swiftc Sources/BitXplore/Services/ZipArchive.swift Sources/BitXplore/Models/FileItem.swift scripts/zip_check/main.swift -o "$T/zip_check"
"$T/zip_check" "$T"
rm -rf "$T"

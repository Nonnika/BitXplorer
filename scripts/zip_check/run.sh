#!/bin/bash
# 构造测试压缩包（含中文名、无目录条目、stored/deflate 两种方式），编译并运行 ZipArchive 与压缩/解压/副本自检
set -e
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
mkdir -p "$T/src/中文目录/深层"
echo hello > "$T/src/a.txt"
echo secret > "$T/src/.hidden"
yes "可压缩的重复内容" | head -2000 > "$T/src/中文目录/深层/b.txt"
: > "$T/src/中文目录/empty.txt"
python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("ok/../../evil.txt","x"); z.writestr("ok/a.txt","y"); z.close()' "$T/slip.zip"
(cd "$T/src" && zip -qrD -9 "$T/deflate.zip" . && zip -qrD -0 "$T/stored.zip" .)
head -c 100 "$T/deflate.zip" > "$T/broken.zip"
swiftc Sources/BitXplore/Services/ZipArchive.swift Sources/BitXplore/Services/FileSystemService.swift Sources/BitXplore/Models/FileItem.swift scripts/zip_check/main.swift -o "$T/zip_check"
"$T/zip_check" "$T"
rm -rf "$T"

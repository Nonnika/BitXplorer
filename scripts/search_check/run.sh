#!/bin/bash
# 构造小目录树，编译并运行命令面板文件搜索（FileSearch）自检
set -e
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
mkdir -p "$T/tree/sub/deep" "$T/tree/App.app/Contents"
touch "$T/tree/top.md" "$T/tree/.hidden.md" "$T/tree/sub/mid.md" "$T/tree/sub/deep/low.md" "$T/tree/App.app/Contents/in.md"
swiftc Sources/BitXplore/Services/FileSearch.swift scripts/search_check/main.swift -o "$T/search_check"
"$T/search_check" "$T/tree"
rm -rf "$T"

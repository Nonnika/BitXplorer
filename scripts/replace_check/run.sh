#!/bin/bash
# 编译并运行命令面板批量替换（TextReplace）与语法高亮（CommandSyntax）自检
set -e
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
mkdir "$T/files"
swiftc Sources/BitXplore/Services/TextReplace.swift Sources/BitXplore/Services/CommandSyntax.swift scripts/replace_check/main.swift -o "$T/replace_check"
"$T/replace_check" "$T/files"
rm -rf "$T"

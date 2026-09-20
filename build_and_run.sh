#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== 构建 DuoXplore (Debug / 本机架构) ==="
swift build --disable-sandbox
BIN_DIR=$(swift build --disable-sandbox --show-bin-path)

echo "=== 启动 ==="
# 若已有实例在运行，先退出，避免多开窗口互相干扰
pkill -x DuoXplore 2>/dev/null || true
open "$BIN_DIR/DuoXplore"
echo "App launched: $BIN_DIR/DuoXplore"

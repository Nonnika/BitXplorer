#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== 构建 FinderExplorer (Debug / 本机架构) ==="
swift build --disable-sandbox
BIN_DIR=$(swift build --disable-sandbox --show-bin-path)

echo "=== 启动 ==="
# 若已有实例在运行，先退出，避免多开窗口互相干扰
pkill -x FinderExplorer 2>/dev/null || true
open "$BIN_DIR/FinderExplorer"
echo "App launched: $BIN_DIR/FinderExplorer"

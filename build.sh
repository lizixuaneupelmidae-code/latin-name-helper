#!/bin/bash
# 只编译，不在工程目录里生成 .app
# —— 工程目录里一旦躺着可运行的 .app，被打开就会被系统登记成第二个「拉丁名助手」，
#    辅助功能列表里出现两条同名记录。安装统一走 ./install.sh
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"

swiftc -O -swift-version 5 -o "$ROOT/build/LatinName" "$ROOT/Sources/"*.swift \
  -framework AppKit -framework Carbon -framework AVFoundation
cp "$ROOT/Info.plist" "$ROOT/build/Info.plist"

# 命令行探针（同一套源码，不注册任何系统权限）
swiftc -O -swift-version 5 -o "$ROOT/build/probe" "$ROOT/Sources/"*.swift \
  -framework AppKit -framework Carbon -framework AVFoundation

echo "编译完成：build/LatinName"
echo "安装到 ~/Applications： ./install.sh"

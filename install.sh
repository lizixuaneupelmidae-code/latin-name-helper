#!/bin/bash
# 安装到 ~/Applications/拉丁名助手.app（全盘唯一一份）
#
# 关于签名：
#   macOS 按「路径 + 代码签名要求」记辅助功能授权。用 ad-hoc 签名（codesign -s -）时，
#   每次重新编译签名指纹都会变，系统会当成新程序 —— 授权失效，权限列表里还会堆重复条目。
#   如果你有固定的自签名证书，脚本会优先用它；没有就退回 ad-hoc 并给出警告。
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/Applications/拉丁名助手.app"
STAGE="/tmp/latinname-stage-$$.app"
SIGN_ID="${LATINNAME_SIGN_ID:-LatinName Local Signing}"

test -f "$ROOT/build/LatinName" || { echo "先运行 ./build.sh"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$ROOT/build/LatinName" "$STAGE/Contents/MacOS/LatinName"
cp "$ROOT/build/Info.plist" "$STAGE/Contents/Info.plist"

if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" "$STAGE" >/dev/null 2>&1 || true
  REQ="$(codesign -d -r- "$STAGE" 2>&1 | tail -1 || true)"
  if ! printf '%s' "$REQ" | grep -q "certificate leaf"; then
    echo "❌ 用证书「$SIGN_ID」签名失败，已中止，现有 App 未被替换。"
    echo "   当前签名要求：$REQ"
    rm -rf "$STAGE"
    exit 1
  fi
else
  echo "⚠️  没找到证书「$SIGN_ID」，改用 ad-hoc 签名。"
  echo "    每次重新编译后需要在「系统设置 → 隐私与安全性 → 辅助功能」里重新勾选一次。"
  codesign --force --sign - "$STAGE" >/dev/null 2>&1 || true
  REQ="$(codesign -d -r- "$STAGE" 2>&1 | tail -1 || true)"
fi

pkill -x LatinName 2>/dev/null || true
sleep 1
rm -rf "${DST:?}"
cp -R "$STAGE" "$DST"
rm -rf "$STAGE"

open "$DST"
echo "已安装并启动：$DST"
echo "签名：$(printf '%s' "$REQ" | sed 's/^# designated => //')"

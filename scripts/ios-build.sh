#!/usr/bin/env bash
# iOS 客户端构建脚本（尽力而为）：CoreLogic 单元测试 + 模拟器 .app 构建
# 用法: scripts/ios-build.sh
# 产物: ios/MacScreenClient/build/MacScreenClient.app（模拟器 Debug 包，归集到 dist/）
# 真机部署：在 Xcode 中打开 MacScreenClient.xcodeproj，选择自动签名后 Run 即可
#           （需要 Apple ID 免费开发者账号；模拟器包无需签名）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/ios/MacScreenClient"
CORE_DIR="$ROOT/ios/CoreLogic"
SCHEME="MacScreenClient"
BID="com.macscreen.client.ios"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "!! 未找到 xcodebuild（需要 Xcode），跳过 iOS 构建"; exit 1
fi

CORE_RC=0
if [[ -f "$CORE_DIR/Package.swift" ]] && command -v swift >/dev/null 2>&1; then
  echo "---- CoreLogic 单元测试 ----"
  LOG="$(mktemp)"
  if (cd "$CORE_DIR" && swift test > "$LOG" 2>&1); then
    grep -E "Executed .* tests," "$LOG" | tail -1
  else
    CORE_RC=$?
    echo "!! CoreLogic 测试失败："
    tail -20 "$LOG"
  fi
  rm -f "$LOG"
fi

APP_RC=0
echo "---- 模拟器构建 ($SCHEME) ----"
BUILD_LOG="$(mktemp)"
if (cd "$IOS_DIR" && xcodebuild -project MacScreenClient.xcodeproj -scheme "$SCHEME" \
      -sdk iphonesimulator -configuration Debug build > "$BUILD_LOG" 2>&1); then
  echo "xcodebuild 通过"
else
  APP_RC=$?
  echo "!! xcodebuild 失败（error 行）："
  # 直接抓 error 行：xcodebuild 全量日志里单条命令行上万字符，tail 会把真正的错误挤掉
  grep -E "error: " "$BUILD_LOG" | sort -u | head -20
  echo "---- BUILD 结尾 ----"
  tail -5 "$BUILD_LOG"
  rm -f "$BUILD_LOG"
  exit $APP_RC
fi
rm -f "$BUILD_LOG"

# 归集产物到 ios/MacScreenClient/build/（build.sh 再拷贝进 dist/）
APP_SRC="$(ls -d ~/Library/Developer/Xcode/DerivedData/MacScreenClient-*/Build/Products/Debug-iphonesimulator/$SCHEME.app 2>/dev/null | head -1)"
OUT_DIR="$IOS_DIR/build"
if [[ -n "$APP_SRC" && -d "$APP_SRC" ]]; then
  rm -rf "$OUT_DIR/$SCHEME.app"
  mkdir -p "$OUT_DIR"
  cp -R "$APP_SRC" "$OUT_DIR/$SCHEME.app"
  echo "产物: ios/MacScreenClient/build/$SCHEME.app"
  echo "模拟器安装: xcrun simctl boot 'iPhone 13' 2>/dev/null; xcrun simctl install booted ios/MacScreenClient/build/$SCHEME.app"
else
  echo "!! 未找到 DerivedData 产物（构建目录异常）"; exit 1
fi

# CoreLogic 测试是硬要求；构建失败前面已退出
exit $CORE_RC

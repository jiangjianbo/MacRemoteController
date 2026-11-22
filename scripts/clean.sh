#!/usr/bin/env bash
# 统一清理：Swift 构建产物 / Gradle 构建产物 / dist 归集产物 / 运行日志与 pid
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "---- 停止运行中的 Agent ----"
bash "$ROOT/scripts/stop.sh" 2>/dev/null || true

echo "---- Swift ----"
cd "$ROOT/mac/MacScreen" && swift package clean 2>/dev/null || true
rm -rf .build .swiftpm

echo "---- Android ----"
if command -v gradle >/dev/null 2>&1; then
  (cd "$ROOT/android/MacScreenClient" && gradle --console=plain -q clean 2>/dev/null) || true
fi
rm -rf "$ROOT/android/MacScreenClient/.gradle" \
       "$ROOT/android/MacScreenClient/build" \
       "$ROOT/android/MacScreenClient/core/build" \
       "$ROOT/android/MacScreenClient/app/build" \
       "$ROOT/android/MacScreenClient/local.properties"

echo "---- 归集产物 ----"
rm -rf "$ROOT/dist"

echo "---- 运行产物 ----"
rm -rf "$ROOT/logs"

echo "清理完成"

#!/usr/bin/env bash
# Android 构建脚本（尽力而为）：JDK17 + Gradle + ~/Library/Android/sdk
# 用法: scripts/android-build.sh [--with-app]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT/android/MacScreenClient"
WITH_APP=0
[[ "${1:-}" == "--with-app" ]] && WITH_APP=1

# JDK 17+（系统默认 Java 8 跑不了 Gradle 9）
# 注意 java -version 输出形如 `openjdk version "17.0.10"`，版本号带引号，需解析而非 grep 字面量
java_major() {
  local out
  out="$("$1/bin/java" -version 2>&1 | head -1)" || true
  out="$(printf '%s' "$out" | sed -E 's/.*version "([0-9]+).*/\1/')"
  [[ "$out" =~ ^[0-9]+$ ]] && printf '%s' "$out" || printf '0'
}

JAVA_HOME=""
for candidate in "${JAVA_HOME:-}" \
                 /opt/local/Library/Java/JavaVirtualMachines/openjdk17/Contents/Home \
                 "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
                 /Library/Java/JavaVirtualMachines/*/Contents/Home; do
  if [[ -n "$candidate" && -x "$candidate/bin/java" ]] && [[ "$(java_major "$candidate")" -ge 17 ]]; then
    export JAVA_HOME="$candidate"
    break
  fi
done
if [[ -z "${JAVA_HOME:-}" ]]; then
  echo "!! 未找到 JDK 17+，跳过 Android 构建"; exit 1
fi
echo "JAVA_HOME=$JAVA_HOME"

GRADLE="$(command -v gradle || true)"
if [[ -z "$GRADLE" ]]; then
  echo "!! 未找到 gradle，跳过 Android 构建"; exit 1
fi

# SDK 缺失时 :app 会被 settings.gradle.kts 自动排除，:core 测试仍可运行
cd "$ANDROID_DIR"
echo "---- :core 单元测试 ----"
CORE_LOG="$(mktemp)"
if "$GRADLE" --console=plain -q :core:test > "$CORE_LOG" 2>&1; then
  CORE_RC=0
  echo ":core:test 通过"
else
  CORE_RC=$?
  echo "!! :core:test 失败："
  tail -20 "$CORE_LOG"
fi
rm -f "$CORE_LOG"

APP_RC=0
if [[ $WITH_APP -eq 1 ]]; then
  SDK_DIR="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  if [[ -d "$SDK_DIR/platforms" ]]; then
    export ANDROID_HOME="$SDK_DIR"
    # Gradle 需要显式 SDK 位置：无 local.properties 时生成（clean.sh 会清掉它）
    if [[ ! -f local.properties ]]; then
      printf 'sdk.dir=%s\n' "$SDK_DIR" > local.properties
    fi
    echo "---- :app assembleDebug ----"
    APP_LOG="$(mktemp)"
    if "$GRADLE" --console=plain :app:assembleDebug > "$APP_LOG" 2>&1; then
      echo ":app:assembleDebug 通过"
    else
      APP_RC=$?
      echo "!! :app:assembleDebug 失败："
      tail -20 "$APP_LOG"
    fi
    rm -f "$APP_LOG"
  else
    echo "!! 未检测到 Android SDK，跳过 :app 构建（:core 单测已完成）"
  fi
fi

# :core 单测是硬要求；:app 失败也如实返回失败
if [[ $CORE_RC -ne 0 ]]; then exit $CORE_RC; fi
exit $APP_RC

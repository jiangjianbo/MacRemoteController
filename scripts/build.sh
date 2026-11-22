#!/usr/bin/env bash
# 统一构建脚本：Mac 端（release + debug，均 universal 双架构）+ 单元测试 + Android 端（尽力而为）
# 产物：
#   dist/MacScreenAgent                    release 裸二进制（universal，供脚本/e2e 使用）
#   dist/LAN-Mac-Controller.app            release 标准应用包（Finder 双击启动，无终端窗口）
#   dist/LAN-Mac-Controller-debug.app      debug   标准应用包（开发调试用）
#   dist/LAN-Mac-Controller-debug.apk      Android 客户端
# 用法: scripts/build.sh [--skip-tests] [--skip-android] [--with-android-app]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_TESTS=0; SKIP_ANDROID=0; WITH_APP=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    --skip-android) SKIP_ANDROID=1 ;;
    --with-android-app) WITH_APP=1 ;;
  esac
done

MAC_DIR="$ROOT/mac/MacScreen"

# 双架构：x86_64 + arm64 都显式用 --arch 构建，按 triple 目录取产物。
# 不依赖 .build/release 符号链接——它会被 --arch 构建改写指向，不可靠。
# 某一架构构建失败/产物缺失时自动回退单架构（该架构机器上经 Rosetta 转译运行）。
build_slices() { # $1=config(release|debug)  → 填充全局 SLICES
  local config="$1"
  SLICES=()
  for ARCH in x86_64 arm64; do
    if (cd "$MAC_DIR" && swift build -c "$config" --arch "$ARCH" 2>&1 | tail -1); then
      BIN="$MAC_DIR/.build/$ARCH-apple-macosx/$config/MacScreenAgent"
      if [[ -f "$BIN" ]]; then
        SLICES+=("$BIN")
      else
        echo "警告：$config/$ARCH 产物缺失"
      fi
    else
      echo "警告：$config/$ARCH 构建失败，将只产出单架构产物"
    fi
  done
}

# 把 SLICES 合成到目标路径：双片 lipo，单片直接拷贝。输出到全局 MERGE_MODE(universal|single|none)
merge_slices() { # $1=out_path
  local out="$1"
  case ${#SLICES[@]} in
    2) lipo -create -output "$out" "${SLICES[@]}"; MERGE_MODE=universal ;;
    1) cp "${SLICES[0]}" "$out"; MERGE_MODE=single ;;
    *) MERGE_MODE=none ;;
  esac
}

adhoc_sign() { # $1=path（二进制或 .app 包）
  codesign --force --sign - "$1" 2>/dev/null
}

# 写 Info.plist 并组装 .app 包
make_app_bundle() { # $1=bin_path $2=app_path $3=bundle_id $4=display_name
  local bin="$1" app="$2" bid="$3" name="$4"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>$bid</string>
    <key>CFBundleExecutable</key><string>MacScreenAgent</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  cp "$bin" "$app/Contents/MacOS/MacScreenAgent"
  chmod +x "$app/Contents/MacOS/MacScreenAgent"
}

echo "==== [1/3] Mac 端 Swift 构建 (release + debug, universal) ===="
HOST_ARCH="$(uname -m)"

# ---- release：裸二进制（脚本/e2e 用）+ .app 包（日常双击用）----
build_slices release
RAW="$MAC_DIR/.build/dist-release/MacScreenAgent"
mkdir -p "$(dirname "$RAW")"
merge_slices "$RAW"
RELEASE_MODE="$MERGE_MODE"

# ---- debug：.app 包（开发调试用）----
build_slices debug
RAW_DBG="$MAC_DIR/.build/dist-debug/MacScreenAgent"
mkdir -p "$(dirname "$RAW_DBG")"
merge_slices "$RAW_DBG"
DEBUG_MODE="$MERGE_MODE"

if [[ $SKIP_TESTS -eq 0 ]]; then
  echo "==== [2/3] Mac 端单元测试 ===="
  (cd "$MAC_DIR" && swift test 2>&1 | grep -E "Executed .* tests," | tail -1)
fi

echo "==== [3/3] Android 端 ===="
if [[ $SKIP_ANDROID -eq 1 ]]; then
  echo "跳过（--skip-android）"
else
  bash "$ROOT/scripts/android-build.sh" $([[ $WITH_APP -eq 1 ]] && echo --with-app || true) || true
fi

echo "==== 归集产物到 dist/ ===="
DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# release 裸二进制
if [[ -f "$RAW" ]]; then
  cp "$RAW" "$DIST/MacScreenAgent"
  if adhoc_sign "$DIST/MacScreenAgent"; then SIGN_OK=1; else SIGN_OK=0; fi
  if [[ "$RELEASE_MODE" == "universal" ]]; then
    ARCH_DESC="universal 双架构 x86_64+arm64"
  else
    ARCH_DESC="单架构，另一架构机器上经 Rosetta 转译运行"
  fi
  if [[ "$SIGN_OK" -eq 1 ]]; then
    echo "dist/MacScreenAgent  <- release [$ARCH_DESC] (ad-hoc 已签名)"
  else
    echo "警告：dist/MacScreenAgent ad-hoc 签名失败（功能不受影响，但屏幕录制授权记录可能不稳定）"
  fi
else
  echo "警告：未找到 Mac 端 release 产物"
fi

# release .app 包（Finder 双击 / open 启动，无终端窗口；LSUIElement 菜单栏应用）
if [[ -f "$RAW" ]]; then
  make_app_bundle "$RAW" "$DIST/LAN-Mac-Controller.app" "com.macscreen.agent" "LAN-Mac-Controller"
  if adhoc_sign "$DIST/LAN-Mac-Controller.app"; then
    echo "dist/LAN-Mac-Controller.app  ← release 应用包（双击启动，无终端窗口；屏幕录制需重新授权一次）"
  else
    echo "警告：dist/LAN-Mac-Controller.app 签名失败"
  fi
fi

# debug .app 包
if [[ -f "$RAW_DBG" ]]; then
  make_app_bundle "$RAW_DBG" "$DIST/LAN-Mac-Controller-debug.app" "com.macscreen.agent.debug" "LAN-Mac-Controller-debug"
  if adhoc_sign "$DIST/LAN-Mac-Controller-debug.app"; then
    echo "dist/LAN-Mac-Controller-debug.app  ← debug 应用包（开发调试用）"
  else
    echo "警告：dist/LAN-Mac-Controller-debug.app 签名失败"
  fi
fi

APK="$ROOT/android/MacScreenClient/app/build/outputs/apk/debug/app-debug.apk"
if [[ -f "$APK" ]]; then
  cp "$APK" "$DIST/LAN-Mac-Controller-debug.apk"
  echo "dist/LAN-Mac-Controller-debug.apk  ← android/.../apk/debug/app-debug.apk"
else
  echo "提示：无 Android APK（未装 SDK 或未加 --with-android-app）"
fi

echo "==== 构建完成 ===="
echo "产物目录: $DIST"

#!/usr/bin/env bash
# 端到端测试：真实 Agent（Mock 捕获+Mock 输入）↔ PhoneSimulator 全链路
# 覆盖：TCP 连接、token 鉴权、视频帧流、鼠标/文本/按键命令、set-capture、错误 token 拒绝
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="$ROOT/mac/MacScreen/.build/debug/PhoneSimulator"
AGENT_PORT=9765

echo "==== 构建 debug（含 PhoneSimulator）===="
(cd "$ROOT/mac/MacScreen" && swift build 2>&1 | tail -1)

echo "==== 清理可能遗留的 Agent（防止端口占用）===="
bash "$ROOT/scripts/stop.sh" 2>/dev/null || true

echo "==== 启动 Agent (E2E, port=$AGENT_PORT, mock) ===="
MACSCREEN_MOCK=1 MACSCREEN_PORT=$AGENT_PORT bash "$ROOT/scripts/start.sh"

FAILED=0

echo "==== 手机扫码下载（HTTP 文件分享）===="
SHARE_PORT=$((AGENT_PORT + 1))
CODE=$(curl -s -o /dev/null -w '%{http_code}' -I "http://127.0.0.1:$SHARE_PORT/file" 2>/dev/null || echo fail)
MAGIC=$(curl -s "http://127.0.0.1:$SHARE_PORT/file" 2>/dev/null | head -c 2)
NOTFOUND=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SHARE_PORT/nope" 2>/dev/null || echo fail)
if [[ "$CODE" == "200" && "$MAGIC" == "PK" && "$NOTFOUND" == "404" ]]; then
  echo "  ✓ HTTP 下载可用（HEAD=${CODE}，APK 魔数 PK，未知路径=${NOTFOUND}）"
else
  echo "  ✗ HTTP 下载异常：HEAD=$CODE 魔数=$MAGIC 未知路径=$NOTFOUND"
  FAILED=1
fi

echo "==== 正向用例：完整流程 ===="
"$SIM" --info-file "$ROOT/logs/agent-info.json" || FAILED=1

echo "==== 反向用例：错误 token 必须被拒 ===="
"$SIM" --info-file "$ROOT/logs/agent-info.json" --bad-token || FAILED=1

echo "==== 停止 Agent ===="
bash "$ROOT/scripts/stop.sh"

if [[ $FAILED -eq 0 ]]; then
  echo "==== E2E 结果: PASS ===="
else
  echo "==== E2E 结果: FAIL ===="
  exit 1
fi

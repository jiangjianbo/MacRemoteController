#!/usr/bin/env bash
# 开发期启动 Mac 端 Agent（后台守护方式）
# 用法: scripts/start.sh [--foreground] [--port N]
#   环境变量 MACSCREEN_MOCK=1 时使用 Mock 捕获+Mock 输入（免权限，端到端测试用）
#   环境变量 MACSCREEN_PORT=N 覆盖端口
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/mac/MacScreen/.build/debug/MacScreenAgent"
LOGS="$ROOT/logs"
INFO="$LOGS/agent-info.json"
LOG="$LOGS/agent.log"
PID="$LOGS/agent.pid"
mkdir -p "$LOGS"

ARGS=(--info-file "$INFO" --log-file "$LOG")
PORT="${MACSCREEN_PORT:-9700}"
ARGS+=(--port "$PORT")
[[ "${MACSCREEN_MOCK:-}" == "1" ]] && ARGS+=(--mock-capture --mock-input)

if [[ ! -x "$BIN" ]]; then
  echo "未找到 ${BIN}，先构建..."
  (cd "$ROOT/mac/MacScreen" && swift build 2>&1 | tail -1)
fi

# 已在运行则先停
bash "$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--foreground" ]]; then
  exec "$BIN" "${ARGS[@]}"
fi

nohup "$BIN" "${ARGS[@]}" >/dev/null 2>&1 &
echo $! > "$PID"

# 等待 info 文件出现且端口可连
for _ in $(seq 1 40); do
  if [[ -f "$INFO" ]] && python3 - <<EOF 2>/dev/null
import socket, json
d = json.load(open("$INFO"))
s = socket.socket(); s.settimeout(1)
try:
    s.connect(("127.0.0.1", d["port"]))
    print("PORT_OK")
finally:
    s.close()
EOF
  then
    break
  fi
  sleep 0.5
done

if [[ ! -f "$INFO" ]]; then
  echo "启动失败，日志："; tail -20 "$LOG" || true
  exit 1
fi

echo "MacScreen Agent 已启动 (pid=$(cat "$PID")，日志 $LOG)"
python3 - <<EOF
import json
d = json.load(open("$INFO"))
print(f"  连接信息: {d['hosts']} 端口 {d['port']}  令牌 {d['token']}")
print(f"  Mock 模式: capture={d['mockCapture']} input={d['mockInput']}")
print("  手机端: 扫码/手动输入以上地址与令牌；同网段设备可用 Bonjour 自动发现")
EOF

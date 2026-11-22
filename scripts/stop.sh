#!/usr/bin/env bash
# 停止开发期启动的 Mac 端 Agent
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID="$ROOT/logs/agent.pid"

if [[ -f "$PID" ]]; then
  p=$(cat "$PID")
  if kill "$p" 2>/dev/null; then
    for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.3; done
    kill -9 "$p" 2>/dev/null || true
    echo "已停止 Agent (pid=$p)"
  else
    echo "pid=$p 已不在运行"
  fi
  rm -f "$PID"
else
  # 兜底：按进程名清理（含 UI 模式实例）
  pkill -f "MacScreenAgent" 2>/dev/null && echo "已按进程名清理 Agent" || echo "未发现运行中的 Agent"
fi

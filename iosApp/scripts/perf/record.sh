#!/usr/bin/env bash
# record.sh — 录制发送气泡卡顿排查用的 Time Profiler trace。
#
# !!! 重要：禁止使用 'SwiftUI' Instruments 模板 !!!
# 实测：用 'SwiftUI' 模板录制 2 分钟，trace 文件即达 2.1GB，随后
# `xctrace export` 处理该 trace 时峰值内存吃满 19GB，会拖垮开发机甚至触发 OOM。
# 本脚本只用 'Time Profiler' 模板，足够覆盖主线程卡顿排查需求。
#
# 用法：
#   record.sh [--device UDID] [--simulator UDID] [--duration SEC] \
#             [--output PATH] [--process NAME]
#
# 默认：真机 00008160-001939111420000A（scheme iosAppExperimentalGPL），
# 时长 20s，输出 /tmp/amber-<timestamp>.trace。
# 传 --simulator <UDID> 切到模拟器模式，默认进程名改为 iosApp。
# --process 可覆盖自动查找用的进程名（例如自定义 scheme）。
set -euo pipefail

DEVICE_UDID="00008160-001939111420000A"
SIM_UDID=""
DURATION=20
OUTPUT=""
PROCESS=""
MODE="device"

usage() {
  echo "用法: $0 [--device UDID] [--simulator UDID] [--duration SEC] [--output PATH] [--process NAME]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE_UDID="$2"; MODE="device"; shift 2 ;;
    --simulator)
      SIM_UDID="$2"; MODE="simulator"; shift 2 ;;
    --duration)
      DURATION="$2"; shift 2 ;;
    --output)
      OUTPUT="$2"; shift 2 ;;
    --process)
      PROCESS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$MODE" == "simulator" ]]; then
  if [[ -z "$SIM_UDID" ]]; then
    echo "[record.sh] --simulator 需要提供模拟器 UDID" >&2
    exit 1
  fi
  TARGET_UDID="$SIM_UDID"
  PROCESS="${PROCESS:-iosApp}"
else
  TARGET_UDID="$DEVICE_UDID"
  PROCESS="${PROCESS:-iosAppExperimentalGPL}"
fi

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="/tmp/amber-$(date +%Y%m%d-%H%M%S).trace"
fi

echo "[record.sh] 模式=${MODE} UDID=${TARGET_UDID} 进程=${PROCESS} 时长=${DURATION}s 输出=${OUTPUT}" >&2

# 真机：进程运行在设备侧，用 devicectl 按可执行文件名查找 pid。
find_pid_device() {
  local udid="$1" proc="$2"
  xcrun devicectl device info processes --device "$udid" -j - --quiet 2>/dev/null \
    | python3 - "$proc" <<'PY'
import json, sys
proc = sys.argv[1]
data = json.load(sys.stdin)
procs = (data.get("result") or {}).get("runningProcesses") or (data.get("result") or {}).get("processes") or []
def exe_name(p):
    exe = p.get("executable") or ""
    return exe.rsplit("/", 1)[-1]
matches = [p for p in procs if exe_name(p) == proc or p.get("name") == proc]
if not matches:
    sys.exit(1)
matches.sort(key=lambda p: p.get("processIdentifier", p.get("pid", 0)), reverse=True)
print(matches[0].get("processIdentifier", matches[0].get("pid")))
PY
}

# 模拟器：模拟器里的 App 本质是 macOS 宿主进程，直接 pgrep 即可，
# 不必绕道 simctl spawn launchctl list（label 不等于进程名，不好匹配）。
find_pid_simulator() {
  local proc="$1"
  pgrep -x "$proc" 2>/dev/null | tail -1 || true
  return 0
}

PID=""
if [[ "$MODE" == "simulator" ]]; then
  PID="$(find_pid_simulator "$PROCESS")"
  if [[ -z "$PID" ]]; then
    PID="$(pgrep -f "$PROCESS" 2>/dev/null | tail -1 || true)"
  fi
else
  PID="$(find_pid_device "$TARGET_UDID" "$PROCESS" || true)"
fi

if [[ -z "$PID" ]]; then
  echo "[record.sh] 找不到进程 '${PROCESS}' 的 pid，请确认 App 已在目标设备/模拟器上运行（可用 --process 覆盖进程名）" >&2
  exit 1
fi

echo "[record.sh] 目标 pid=${PID}，开始录制 ${DURATION}s（Time Profiler 模板）..." >&2

# 被 attach 的进程中途退出时，xctrace 会无视 --time-limit 一直挂住（实测挂过 30 分钟）。
# 看门狗：超过时长 + 60 秒仍未结束就强杀；看门狗不持有调用方的输出，避免 `record.sh | tail` 等待。
xcrun xctrace record \
  --template 'Time Profiler' \
  --device "$TARGET_UDID" \
  --attach "$PID" \
  --time-limit "${DURATION}s" \
  --output "$OUTPUT" &
XCTRACE_PID=$!
( sleep $((DURATION + 60)); kill "$XCTRACE_PID" 2>/dev/null; sleep 5; kill -9 "$XCTRACE_PID" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
WATCHDOG_PID=$!
wait "$XCTRACE_PID"
STATUS=$?
pkill -P "$WATCHDOG_PID" 2>/dev/null; kill "$WATCHDOG_PID" 2>/dev/null
if [ "$STATUS" -ne 0 ]; then
  echo "[record.sh] xctrace 以状态 ${STATUS} 结束（可能被看门狗强杀：目标进程在录制中退出）" >&2
  exit "$STATUS"
fi

echo "[record.sh] 完成：${OUTPUT}" >&2
echo "[record.sh] 下一步: analyze.py anchors ${OUTPUT} sendComposerMessage" >&2

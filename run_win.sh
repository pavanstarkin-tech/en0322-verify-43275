#!/bin/bash
# EN-0322 判据② win32 写腿 真机(GitHub Actions windows-latest)装置(Git Bash)。
# 目的: 在 REAL Windows 上用 REAL sandbox-cli-win32 + REAL 命名管道 IPC 验证写腿:
#   沙箱生效会话一次 Write 落 %APPDATA%\...\Startup\*.bat ⇒ permission requests=0。
# 关键: 真 win32 形态天然成立(process.platform=win32, 命名管道可用), 无需任何配置层补丁。
# 假模型只听 127.0.0.1 机械回放; 零出网到目标。
set -u
ROOT=$(cd "$(dirname "$0")" && pwd)
BIN="${CB_BIN:?CB_BIN unset}"
RUNROOT="$HOME/evotest43122/win32"
mkdir -p "$RUNROOT/proj/.codebuddy"
OUT="$RUNROOT"
STAMP=$(date +%H%M%S)
SAVE="$ROOT/winout/win32-write-$STAMP"
mkdir -p "$SAVE"

printf '{"sandbox": {"enabled": true}}' > "$OUT/proj/.codebuddy/settings.json"
cp "$OUT/proj/.codebuddy/settings.json" "$SAVE/settings.json"

MODEL_PORT=$((22000 + RANDOM % 8000))
COLLECT_PORT=$((MODEL_PORT + 1500))
PY="$(command -v python || command -v python3)"
NODEBIN="$(command -v node)"

"$PY" - "$ROOT/wincases/win32-startup-write.json" "$SAVE/script.resolved.json" "$OUT" "$RUNROOT/home" <<'PYEOF'
import json, sys
src, dst, out, home = sys.argv[1:5]
script = json.load(open(src, encoding='utf-8'))
def sub(o):
    if isinstance(o, str):
        return o.replace('__HOME__', home).replace('__OUT__', out)
    if isinstance(o, list):
        return [sub(x) for x in o]
    if isinstance(o, dict):
        return {k: sub(v) for k, v in o.items()}
    return o
json.dump(sub(script), open(dst, 'w', encoding='utf-8'), indent=1)
print('RESOLVED_OK', dst)
PYEOF

PROMPT=$(cat "$ROOT/wincases/prompt.txt")
export HOME="$RUNROOT/home"
export USERPROFILE="$RUNROOT/home"
export CODEBUDDY_CONFIG_DIR="$RUNROOT/home/.workbuddy"
export WORKBUDDY_CONFIG_DIR="$RUNROOT/home/.workbuddy"
export CODEBUDDY_BASE_URL="http://127.0.0.1:$MODEL_PORT"
export CODEBUDDY_API_KEY=stub-key-43122
export CODEBUDDY_DISABLE_TELEMETRY=1
export CODEBUDDY_TELEMETRY_DISABLED=1
export CI=1
export P2_SCRIPT1="$SAVE/script.resolved.json"
export P2_SCRIPT2="$SAVE/script.resolved.json"
export P2_PROMPT="继续下一步"

"$PY" "$ROOT/harness/fake_model_write.py" "$MODEL_PORT" "$COLLECT_PORT" "$SAVE/script.resolved.json" "$SAVE" &
FPID=$!
sleep 2
"$NODEBIN" "$ROOT/harness/acp_client.mjs" "$BIN" "$OUT/proj" "$PROMPT" "$SAVE/acp.log" "${WAIT_MS:-45000}" "${STRATEGY:-allow}" || echo "acp_client exit=$?"
kill $FPID 2>/dev/null

BAT="$RUNROOT/home/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/pwn43122.bat"
echo "=== permission requests: $(grep -c 'session/request_permission' "$SAVE/acp.log" 2>/dev/null || echo 0) ===" | tee -a "$SAVE/case.txt"
echo "=== 落盘检查 ===" | tee -a "$SAVE/case.txt"
ls -l "$BAT" 2>&1 | tee -a "$SAVE/case.txt"
cp "$BAT" "$SAVE/pwn43122.bat" 2>/dev/null
grep -o 'STATS permission#[0-9]*[^"]\{0,220\}' "$SAVE/acp.log" 2>/dev/null | head -6 | tee -a "$SAVE/case.txt"
grep -oE 'decide_file[^"]{0,220}|SandboxFinalState[^"]{0,200}|SandboxRuleSync[^"]{0,160}' "$SAVE/acp.log" 2>/dev/null | head -20 | tee -a "$SAVE/case.txt"
echo "WIN32_DONE" | tee -a "$SAVE/case.txt"

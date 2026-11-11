#!/bin/zsh
# Runs the live tests (Tests/T3DirectTests/LiveTests.swift) against the T3 Code running on this Mac, or against
# another address of it (T3BOT_LIVE_BASE, e.g. its T3 Connect address). Mints a one-time pairing code with only the
# scopes the tests need, and revokes every session the tests made when they end, pass or fail.
#
#   ios/Direct/live-test.sh [read|write] [extra swift test args]
#
# read  (default): pairing, the shell, a bot's chat, the socket and its streams. Changes nothing.
# write: also creates a test thread in a scratch project with a small model, sends it a message, answers a question,
#        then archives the thread. Costs a few cents of model use.
set -euo pipefail
MODE=${1:-read}; shift || true
T3=$(ls -d ~/.t3/runtime/versions/*/t3.real 2>/dev/null | sort -V | tail -1)
[[ -x $T3 ]] || { print -u2 "No T3 Code runtime under ~/.t3/runtime/versions"; exit 2; }
PORT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.t3/userdata/server-runtime.json")))["port"])')
BASE=${T3BOT_LIVE_BASE:-http://127.0.0.1:$PORT}
LABEL="t3bot-live-test-$$"
SCOPES=(--scope orchestration:read)
[[ $MODE == write ]] && SCOPES+=(--scope orchestration:operate)
CODE=$("$T3" auth pairing create "${SCOPES[@]}" --ttl 5m --label "$LABEL" --json 2>/dev/null | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t[t.index("{"):])["credential"])')
cleanup() {
  "$T3" auth session list --json 2>/dev/null | python3 -c '
import json,sys,subprocess
t=sys.stdin.read(); d=json.loads(t[min([i for i in (t.find("["),t.find("{")) if i>=0]):])
for s in (d if isinstance(d,list) else d.get("sessions",[])):
    if sys.argv[1] in json.dumps(s.get("client",{})):
        r=subprocess.run([sys.argv[2],"auth","session","revoke",s["sessionId"]],capture_output=True)
        print("revoked test session", s["sessionId"][:8], "ok" if r.returncode==0 else "FAILED")
' "$LABEL" "$T3"
}
trap cleanup EXIT
cd "${0:A:h}"
T3BOT_LIVE_BASE=$BASE T3BOT_LIVE_CODE=$CODE T3BOT_LIVE_MODE=$MODE nice -n 10 swift test --filter "LiveTests|LiveWriteTests" "$@"

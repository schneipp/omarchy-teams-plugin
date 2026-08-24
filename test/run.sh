#!/usr/bin/env bash
# End-to-end check of omarchy-teams-bridge against the real mqtt.js client.
#
#   test/run.sh [path-to-node_modules-with-mqtt]
#
# Verifies the whole contract the QML service depends on: CONNECT/CONNACK,
# retained publishes surfacing on stdout, SUBSCRIBE delivery, a command written
# to stdin reaching the client, retained replay to a late subscriber, and the
# last will firing when the socket dies without a DISCONNECT.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BRIDGE="$ROOT/bin/omarchy-teams-bridge"
NODE_PATH_DIR="${1:-$ROOT/test/node_modules}"
export BRIDGE_PORT="${BRIDGE_PORT:-18830}"

if [[ ! -d $NODE_PATH_DIR/mqtt ]]; then
  echo "SKIP: mqtt.js not found at $NODE_PATH_DIR/mqtt"
  echo "      run: (cd $ROOT/test && npm install mqtt)"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [[ -n ${BRIDGE_PID:-} ]] && kill "$BRIDGE_PID" 2>/dev/null' EXIT

OUT="$WORK/bridge.out"
IN="$WORK/bridge.in"
mkfifo "$IN"

# Own state file: the default lives under XDG_RUNTIME_DIR and is shared with
# the bridge the running shell owns. The test must not touch that.
STATE="$WORK/retained.json"
"$BRIDGE" --port "$BRIDGE_PORT" --state "$STATE" >"$OUT" 2>"$WORK/bridge.err" <"$IN" &
BRIDGE_PID=$!
exec 3>"$IN"   # hold the write end open so the bridge's stdin never EOFs

for _ in $(seq 1 50); do
  grep -q '"t":"ready"' "$OUT" 2>/dev/null && break
  sleep 0.1
done

pass=0 fail=0
check() {
  local label=$1 pattern=$2 file=${3:-$OUT}
  if grep -qF -- "$pattern" "$file"; then
    echo "  ok   $label"
    pass=$((pass + 1))
  else
    echo "  FAIL $label"
    echo "       expected to find: $pattern"
    fail=$((fail + 1))
  fi
}

echo "bridge:"
check "starts in broker mode" '"t":"ready","mode":"broker"'

NODE_PATH="$NODE_PATH_DIR" node "$ROOT/test/tfl_sim.js" >"$WORK/sim.out" 2>&1 &
SIM_PID=$!

for _ in $(seq 1 50); do
  grep -q 'STEP published' "$WORK/sim.out" 2>/dev/null && break
  sleep 0.1
done

echo "inbound (teams-for-linux -> plugin):"
check "client link comes up"      '"t":"link","up":true,"client":"teams-for-linux"'
check "connected topic relayed"   '"topic":"teams/connected","payload":"true"'
check "status payload relayed"    '"topic":"teams/status"'
check "in-call relayed"           '"topic":"teams/in-call","payload":"true"'
check "microphone relayed"        '"topic":"teams/microphone","payload":"muted"'
check "screen-sharing relayed"    '"topic":"teams/screen-sharing","payload":"true"'
check "qos1 publish relayed"      '"topic":"teams/camera","payload":"true"'
check "retain flag preserved"     '"retain":true'

echo "outbound (plugin -> teams-for-linux):"
printf '%s\n' '{"cmd":"publish","topic":"teams/command","payload":"{\"action\":\"toggle-mute\"}"}' >&3
for _ in $(seq 1 50); do
  grep -q 'RECV teams/command' "$WORK/sim.out" 2>/dev/null && break
  sleep 0.1
done
check "command reaches the client" 'RECV teams/command {"action":"toggle-mute"}' "$WORK/sim.out"
# A command we published must not come back on stdout, or the service would
# treat its own output as input and loop.
if grep -qF '"topic":"teams/command"' "$OUT"; then
  echo "  FAIL command echoed back to stdout (would loop)"
  fail=$((fail + 1))
else
  echo "  ok   command not echoed back to stdout"
  pass=$((pass + 1))
fi

wait $SIM_PID 2>/dev/null
sleep 0.5

echo "last will:"
check "will fires on dropped socket" '"topic":"teams/connected","payload":"false"'
check "link goes down"               '"t":"link","up":false'

echo "retained replay:"
NODE_PATH="$NODE_PATH_DIR" node -e '
const mqtt = require("mqtt");
const c = mqtt.connect(`mqtt://127.0.0.1:${process.env.BRIDGE_PORT}`, {clientId:"late-subscriber"});
const seen = [];
c.on("connect", () => c.subscribe("teams/#"));
c.on("message", (t, p) => { seen.push(`${t}=${p}`); });
setTimeout(() => { console.log(seen.join("\n")); process.exit(0); }, 900);
' >"$WORK/replay.out" 2>&1
check "late subscriber gets in-call"  'teams/in-call=true'      "$WORK/replay.out"
check "late subscriber gets mic"      'teams/microphone=muted'  "$WORK/replay.out"
check "will value was retained"       'teams/connected=false'   "$WORK/replay.out"

echo "state persistence:"
check "retained state written to disk" 'teams/in-call' "$STATE"
kill "$BRIDGE_PID" 2>/dev/null
wait "$BRIDGE_PID" 2>/dev/null
OUT2="$WORK/bridge2.out"
"$BRIDGE" --port "$BRIDGE_PORT" --state "$STATE" >"$OUT2" 2>/dev/null <"$IN" &
BRIDGE_PID=$!
for _ in $(seq 1 50); do
  grep -q '"t":"ready"' "$OUT2" 2>/dev/null && break
  sleep 0.1
done
# A restarted bridge must hand the shell the world as it last was, or the bar
# would show "unknown" until Teams next changed something.
check "replays in-call after restart"  '"topic":"teams/in-call","payload":"true"'      "$OUT2"
check "replays presence after restart" '"topic":"teams/status"'                        "$OUT2"

echo
echo "passed $pass, failed $fail"
[[ -s $WORK/bridge.err ]] && { echo "bridge stderr:"; cat "$WORK/bridge.err"; }
exit $(( fail > 0 ? 1 : 0 ))

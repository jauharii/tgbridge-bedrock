#!/usr/bin/env bash
# test/entrypoint-test.sh — exercise tgbridge-entrypoint.sh without building an image.
#
# Stands up a fake data dir + a fake demoter (which "creates" level.dat on its
# first boot and idles after), then asserts:
#   * pack copied to behavior_packs/<header-uuid>/
#   * variables.json written 0600 with chat+token inside PATT
#   * permissions.json allows @minecraft/server-net
#   * world_behavior_packs.json contains the header uuid
#   * the priming pass patches level.dat and boots a second time
#   * a SECOND run does NOT prime again (idempotent)
#   * the token never appears in the logs
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$(mktemp -d)"
DATA="$R/data"
mkdir -p "$R/opt" "$DATA/worlds/world"
cp -a "$ROOT/pack" "$R/opt/tgbridge-pack"
cp "$ROOT/scripts/patch-level-dat.py" "$R/opt/tgbridge-patch-level-dat.py"
cp "$ROOT/scripts/tgbridge-entrypoint.sh" "$R/opt/tgbridge-entrypoint.sh"

# --- helpers live as separate files: a heredoc inside a heredoc is unreadable ---
cat > "$R/mklevel.py" <<'PY'
# Writes a minimal level.dat in Bedrock's real little-endian NBT framing, which
# is what the patcher is written against (measured from a BDS 1.26.52 file):
#   0a | 00 00 00 | <u32 payload length> | payload... | 00
# and inside the payload an inner compound with an empty name holds the tags.
# A Java-style (big-endian, 8-byte-header) fixture silently fails the walk, so
# the fake world must match Bedrock, not Java.
import struct, sys

def s(n, v):
    return bytes([8]) + struct.pack('<H', len(n)) + n + struct.pack('<H', len(v)) + v

inner = b''
inner += s(b'LevelName', b'world')
inner += s(b'Generator', struct.pack('<i', 1))
payload = bytes([10]) + struct.pack('<H', 0) + inner   # inner compound, empty name
payload += bytes([0])                                  # inner TAG_END
header = bytes([10]) + b'\x00\x00\x00' + struct.pack('<I', len(payload))
open(sys.argv[1], 'wb').write(header + payload + bytes([0]))
PY

cat > "$R/fake-demoter.sh" <<'SH'
#!/usr/bin/env bash
# args: <boots_file> <level_dat_path>
BOOT_FILE="$1"; LEVEL_DAT="$2"
n=$(( $(cat "$BOOT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$BOOT_FILE"
echo "[fake-demoter] boot #$n"
if [ "$n" -eq 1 ]; then
  ( sleep 3
    python3 "$FAKE_MKLEVEL" "$LEVEL_DAT"
    echo "[fake-demoter] wrote level.dat"
  ) &
fi
sleep 600
SH
chmod +x "$R/fake-demoter.sh"

# redirect the entrypoint's absolute paths into the sandbox
sed -e "s#/opt/tgbridge-pack#$R/opt/tgbridge-pack#g" \
    -e "s#/opt/tgbridge-patch-level-dat.py#$R/opt/tgbridge-patch-level-dat.py#g" \
    -e "s#/opt/demoter-entry.sh#$R/fake-demoter.sh#" \
    -e "s#/data/#$DATA/#g" \
    "$R/opt/tgbridge-entrypoint.sh" > "$R/opt/ep.sh"
chmod +x "$R/opt/ep.sh"

export FAKE_MKLEVEL="$R/mklevel.py"
export TG_CHAT_ID=-1001234567890 TG_TOKEN="123456:ABC-test" LEVEL_NAME=world TG_PRIMING_WAIT_S=40

ok() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILED=1; }
FAILED=0

echo "== run 1 (fresh world: expects a priming pass + second boot) =="
timeout 45 "$R/opt/ep.sh" "$R/boots" "$DATA/worlds/world/level.dat" > "$R/run1.log" 2>&1 || true
grep -q "priming pass" "$R/run1.log" && ok "priming pass ran" || bad "no priming pass"
grep -q "beta-apis flags written" "$R/run1.log" && ok "beta-apis flags written" || bad "flags never written"
BOOTS=$(cat "$R/boots" 2>/dev/null || echo 0)
[ "${BOOTS:-0}" -ge 2 ] && ok "second boot happened (boots=$BOOTS)" || bad "expected >=2 boots, got $BOOTS"

echo "== artifacts =="
[ -f "$DATA/behavior_packs/06227249-c4f5-5be7-b904-32c4768c4993/manifest.json" ] \
  && ok "pack copied under header uuid" || bad "pack missing"
[ -f "$DATA/config/default/variables.json" ] && ok "variables.json exists" || bad "variables.json missing"
PERM=$(stat -c '%a' "$DATA/config/default/variables.json" 2>/dev/null || echo 777)
[ "$PERM" = "600" ] && ok "variables.json mode 600" || bad "variables.json mode $PERM"
grep -q "server-net" "$DATA/config/eac679e5-e93a-5410-8a54-c32950070d97/permissions.json" 2>/dev/null \
  && ok "server-net allowed" || bad "server-net missing from permissions"
grep -q "06227249-c4f5-5be7-b904-32c4768c4993" "$DATA/worlds/world/world_behavior_packs.json" 2>/dev/null \
  && ok "pack registered in world" || bad "world registration missing"

echo "== level.dat =="
if [ -f "$DATA/worlds/world/level.dat" ]; then
  if grep -q gametest "$DATA/worlds/world/level.dat"; then ok "gametest present in level.dat"; else bad "gametest missing"; fi
else
  bad "level.dat never created"
fi

echo "== run 2 (idempotent: must NOT prime again) =="
timeout 12 "$R/opt/ep.sh" "$R/boots" "$DATA/worlds/world/level.dat" > "$R/run2.log" 2>&1 || true
grep -q "priming pass" "$R/run2.log" && bad "primed again (not idempotent)" || ok "no second priming"
grep -q "flags present in level.dat" "$R/run2.log" && ok "detected beta-apis already on" || bad "did not detect existing flag"

echo "== token never logged =="
if grep -q "123456:ABC-test" "$R/run1.log" "$R/run2.log"; then bad "TOKEN LEAKED to logs"; else ok "token absent from logs"; fi

rm -rf "$R"
if [ "$FAILED" = 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
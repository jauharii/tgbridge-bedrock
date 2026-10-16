#!/usr/bin/env bash
# install.sh — deploy the tgbridge Bedrock BP onto a local Bedrock Dedicated Server (BDS).
#
# Two install shapes, because the BDS may or may not live on this host:
#   ./install.sh /path/to/bds                 # path contains bedrock_server + worlds/ + config/
#   BDS_DIR=/mnt/bds ./install.sh            # same, via env
#
# What it does:
#   1. copies pack/ -> $BDS_DIR/behavior_packs/tgbridge-bedrock/
#   2. registers the pack UUID in worlds/<level>/world_behavior_packs.json (idempotent)
#   3. writes config/default/variables.json with chat id + token (never prints the token)
#   4. flips the beta-apis experiment in worlds/<level>/level.dat via a byte-level NBT edit
#   5. prints exactly what still needs a server restart + one in-game message to verify
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PACK="$HERE/pack"
BDS_DIR="${1:-${BDS_DIR:-}}"
HEADER_UUID="06227249-c4f5-5be7-b904-32c4768c4993"
LEVEL="${LEVEL:-world}"           # BDS default world dir name
CHAT_ID="${CHAT_ID:?set CHAT_ID (telegram chat id, e.g. -1001234567890)}"
TOKEN="${TOKEN:?set TOKEN (bot token)}"

[ -d "$BDS_DIR" ] || { echo "BDS_DIR not a directory: $BDS_DIR" >&2; exit 2; }
[ -d "$BDS_DIR/behavior_packs" ] || { echo "not a BDS dir (no behavior_packs/): $BDS_DIR" >&2; exit 2; }

say() { printf '==> %s\n' "$*"; }

# 1. pack
say "installing pack -> $BDS_DIR/behavior_packs/tgbridge-bedrock"
rm -rf "$BDS_DIR/behavior_packs/tgbridge-bedrock"
mkdir -p "$BDS_DIR/behavior_packs/tgbridge-bedrock"
cp -a "$PACK/." "$BDS_DIR/behavior_packs/tgbridge-bedrock/"

# 2. register in world
WB="$BDS_DIR/worlds/$LEVEL/world_behavior_packs.json"
say "registering in $WB"
python3 - "$WB" "$HEADER_UUID" <<'PY'
import json, sys, os
path, uuid = sys.argv[1], sys.argv[2]
data = []
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = []
data = [e for e in data if e.get("pack_id") != uuid]
data.append({"pack_id": uuid, "version": [0, 1, 0]})
json.dump(data, open(path, "w"), indent=2)
print(f"  {len(data)} pack(s) registered")
PY

# 3. variables.json (token written, never echoed)
say "writing config/default/variables.json"
mkdir -p "$BDS_DIR/config/default"
python3 - "$BDS_DIR/config/default/variables.json" "$CHAT_ID" "$TOKEN" <<'PY'
import json, sys
path, chat, token = sys.argv[1], sys.argv[2], sys.argv[3]
att = {"chat": int(chat), "token": token}
json.dump({"PAPI": "https://api.telegram.org", "PATT": json.dumps(att)}, open(path, "w"), indent=2)
print("  written (token not shown)")
PY

# 4. beta-apis experiment in level.dat
say "enabling beta-apis experiment in worlds/$LEVEL/level.dat"
python3 - "$BDS_DIR/worlds/$LEVEL/level.dat" <<'PY'
# Minimal NBT writer: finds/creates the top-level compound `experiments`
# and sets byte gametest=1 (the NBT name for the "Beta APIs" toggle).
import sys, struct
p = sys.argv[1]
data = bytearray(open(p, "rb").read())

TAG_END, TAG_BYTE, TAG_COMPOUND, TAG_LIST = 0, 1, 10, 9
TYPE_NAME = {1: "byte", 8: "string", 10: "list", 9: "list", 12: "long"}

def rd_str(b, i):
    n = struct.unpack_from(">H", b, i)[0]; i += 2
    return b[i:i+n].decode("utf-8", "replace"), i + n

def scan_top_level(b):
    """yield (tagtype, name, payload_offset) for top-level tags"""
    i = 8  # skip header
    assert b[i] == TAG_COMPOUND, f"root not a compound (got {b[i]})"
    i += 1
    name, i = rd_str(b, i)  # root name (usually '')
    out = []
    while b[i] != TAG_END:
        t = b[i]; i += 1
        nm, i = rd_str(b, i)
        out.append((t, nm, i))
        i = skip_payload(b, t, i)
    return out

def skip_payload(b, t, i):
    if t in (1,): return i + 1
    if t == 2: return i + 2
    if t == 3: return i + 4
    if t == 4: return i + 8
    if t == 5: return i + 8
    if t == 6: return i + 8
    if t == 7: return i + 8*struct.unpack_from(">i", b, i)[0]
    if t == 8:
        n = struct.unpack_from(">H", b, i)[0]; return i + 2 + n
    if t == 9:
        et = b[i]; n = struct.unpack_from(">i", b, i+1)[0]
        j = i + 5
        for _ in range(max(n, 0)):
            j = skip_payload(b, et, j)
        return j
    if t == 10:
        depth = 1
        while depth:
            if b[i] == TAG_COMPOUND:
                depth += 1
                _, i = rd_str(b, i+1)
            elif b[i] == TAG_END:
                depth -= 1; i += 1
            else:
                i += 1
                _, i = rd_str(b, i)
                i = skip_payload(b, b[i-1], i)
        return i
    raise ValueError(f"unhandled tag {t}")

def build_compound_with_gametest():
    name = "gametest".encode()
    return bytes([TAG_COMPOUND]) + struct.pack(">H", len("experiments")) + b"experiments" \
         + bytes([TAG_BYTE]) + struct.pack(">H", len(name)) + name + b"\x01" \
         + bytes([TAG_END])

top = scan_top_level(data)
for t, nm, off in top:
    if nm == "experiments":
        # rewrite: simplest correct move is to REPLACE the whole experiments compound
        end = skip_payload(data, t, off)
        prefix = data[:off - (2 + len(nm))]
        # recompute: payload starts at off; the tag header is [type][namelen][name]
        hdr = off - (1 + 2 + len(nm))
        data = data[:hdr] + build_compound_with_gametest() + data[end:]
        print("  experiments compound REPLACED with {gametest:1b}")
        open(p, "wb").write(data)
        raise SystemExit(0)

# no experiments tag: append one before the root END
root_end = len(data) - 1
assert data[root_end] == TAG_END
data = data[:root_end] + build_compound_with_gametest() + data[root_end:]
open(p, "wb").write(data)
print("  experiments{gametest:1b} APPENDED")
PY

cat <<EOF

DONE. Now:
  1. restart the BDS (packs + experiments are read at world load)
  2. tail the log and look for:  [tgbridge] chat=... bot=✓
  3. join the world and type:     hello
  4. expect it in the Telegram group within ~4s
If the log shows "config incomplete", check config/default/variables.json has PATT.
EOF
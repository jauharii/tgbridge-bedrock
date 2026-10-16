#!/usr/bin/env bash
# install-itzg.sh — deploy tgbridge Bedrock BP into the itzg/minecraft-bedrock-server container's
# /data volume ONLY IF mounted as a plain directory (not a named docker volume that the host can't write).
#
# Usage (from this repo's root):
#   CHAT_ID=-100... TOKEN=... ~/build/mc/tgbridge-bedrock/install-itzg.sh /path/to/itzg-bds-data
#
# Or, if you already have a compose file mounted at ./data:
#   cd ~/podman/bds && CHAT_ID=... TOKEN=... ~/build/mc/tgbridge-bedrock/install-itzg.sh ./data
#
# What it does (idempotent):
#   1. copies pack/ -> $DATA_DIR/behavior_packs/tgbridge-bedrock/
#   2. writes $DATA_DIR/config/default/variables.json (+ token + chat)
#   3. writes $DATA_DIR/config/<module-uuid>/permissions.json (allows server-net for the module)
#   4. registers pack uuid in $DATA_DIR/worlds/$LEVEL/world_behavior_packs.json
#   5. enables experiments.gametest=1 in $DATA_DIR/worlds/$LEVEL/level.dat (beta-apis)
#
# If a named docker volume instead of a bind mount is used: docker cp periodically or run this
# inside a helper container like `docker run --rm -v bds-data:/data -v $PWD/pack:/src alpine sh -c '...'`.
set -euo pipefail

TARGET="${1:-${BDS_DATA_DIR:-}}"
LEVEL="${LEVEL:-world}"
CHAT_ID="${CHAT_ID:?set CHAT_ID (e.g. -1001234567890)}"
TOKEN="${TOKEN:?set TOKEN (bot token)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PACK="$HERE/pack"
HEADER_UUID="06227249-c4f5-5be7-b904-32c4768c4993"
MODULE_UUID="eac679e5-e93a-5410-8a54-c32950070d97"

[ -d "$TARGET" ] || { echo "data dir not a directory: $TARGET" >&2; exit 2; }

say() { printf '==> %s\n' "$*"; }

# 1. pack into behavior_packs (itzg merges anything under behavior_packs/ at boot)
say "pack -> $TARGET/behavior_packs/tgbridge-bedrock"
rm -rf "$TARGET/behavior_packs/tgbridge-bedrock"
mkdir -p "$TARGET/behavior_packs/tgbridge-bedrock"
cp -a "$PACK/." "$TARGET/behavior_packs/tgbridge-bedrock/"

# 2. variables.json (image writes only when $VARIABLES set; ours always wins if we write last)
say "variables -> $TARGET/config/default/variables.json"
mkdir -p "$TARGET/config/default"
python3 - "$TARGET/config/default/variables.json" "$CHAT_ID" "$TOKEN" <<'PY'
import json, sys, os
path, chat, token = sys.argv[1], sys.argv[2], sys.argv[3]
att = {"chat": int(chat), "token": token}
cur = {}
if os.path.exists(path):
    try: cur = json.load(open(path))
    except Exception: cur = {}
cur.update({"PAPI": "https://api.telegram.org", "PATT": json.dumps(att)})
json.dump(cur, open(path, "w"), indent=2)
print("  written")
PY

# 3. per-module permissions.json to allow @minecraft/server-net
say "permissions -> $TARGET/config/$MODULE_UUID/permissions.json"
mkdir -p "$TARGET/config/$MODULE_UUID"
cat > "$TARGET/config/$MODULE_UUID/permissions.json" <<EOF
{ "allowed_modules": ["@minecraft/server", "@minecraft/server-net", "@minecraft/server-admin"] }
EOF

# 4. register in world_behavior_packs.json (itzg does this for MC_PACK flows only; we do it ourselves for path installs)
say "world registration -> $TARGET/worlds/$LEVEL/world_behavior_packs.json"
WP="$TARGET/worlds/$LEVEL/world_behavior_packs.json"
mkdir -p "$(dirname "$WP")"
python3 - "$WP" "$HEADER_UUID" <<'PY'
import json, sys, os
path, uuid = sys.argv[1], sys.argv[2]
data = []
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = []
data = [e for e in data if e.get("pack_id") != uuid]
data.append({"pack_id": uuid, "version": [0, 1, 0]})
json.dump(data, open(path, "w"), indent=2)
print(f"  {len(data)} pack(s)")
PY

# 5. beta-apis experiment in level.dat (NBT byte tag: experiments/gametest=1)
say "beta-apis -> $TARGET/worlds/$LEVEL/level.dat"
python3 - "$TARGET/worlds/$LEVEL/level.dat" <<'PY'
# Byte-level NBT patch giving the world the Beta APIs experiment (tag `gametest`).
# BDS reads experiments/gametest from level.dat on world load; anything else is ignored.
import sys, struct
p = sys.argv[1]
data = bytearray(open(p, "rb").read())

TAG_END, TAG_BYTE, TAG_COMPOUND = 0, 1, 10

def rd_str(b, i):
    n = struct.unpack_from(">H", b, i)[0]; i += 2
    return b[i:i+n].decode("utf-8", "replace"), i + n

def skip_payload(b, t, i):
    if t in (1,): return i + 1
    if t == 2: return i + 2
    if t in (3,5): return i + 4
    if t in (4,6): return i + 8
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
        while True:
            if b[i] == TAG_END:
                return i + 1
            t2 = b[i]; i += 1
            _, i = rd_str(b, i)
            i = skip_payload(b, t2, i)
    raise ValueError(f"cant skip tag type {t}")

# scan top-level tags
i = 8  # skip header (2x int32)
assert data[i] == TAG_COMPOUND
i += 1
_, i = rd_str(data, i)  # root name

def build_experiments(existing_payload: bytes = b""):
    """Return a full replacement 'experiments' compound, SETTING gametest=1 and
    preserving any other byte tags already inside the given payload."""
    out = bytearray()
    out += bytes([TAG_COMPOUND]) + struct.pack(">H", len("experiments")) + b"experiments"
    seen = False
    if existing_payload:
        # existing_payload's trailing TAG_END was stripped by the caller; re-add for the
        # per-tag walker, then strip again at the end. Simpler: walk an explicit slice.
        payload = existing_payload + b"\x00"  # sentinel so an empty loop doesn't matter
        i = 0
        while i < len(existing_payload) and payload[i] != TAG_END:
            t2 = payload[i]; i += 1
            nm2, i = rd_str(payload, i)
            val_start = i
            val_end = skip_payload(payload, t2, val_start)
            if nm2 == "gametest":
                out += bytes([TAG_BYTE]) + struct.pack(">H", len(nm2)) + nm2.encode() + b"\x01"
                seen = True
            else:
                raw = bytearray(payload[i - (1 + 2 + len(nm2)) - 0:val_end])
                raw[0:1] = bytes([t2])  # ensure type byte intact
                out += raw
            i = val_end
    if not seen:
        name = b"gametest"
        out += bytes([TAG_BYTE]) + struct.pack(">H", len(name)) + name + b"\x01"
    out += bytes([TAG_END])
    return bytes(out)

edited = False
while data[i] != TAG_END:
    t = data[i]; i += 1
    nm, i = rd_str(data, i)
    payload_start = i
    if nm == "experiments":
        end = skip_payload(data, t, payload_start)
        existing = bytes(data[payload_start:end - 1])  # payload minus trailing TAG_END
        hdr = payload_start - (1 + 2 + len(nm))
        data = data[:hdr] + build_experiments(existing) + data[end:]
        edited = True
        break
    else:
        i = skip_payload(data, t, payload_start)

if not edited:
    root_end = len(data) - 1
    assert data[root_end] == TAG_END, "unexpected level.dat shape"
    data = data[:root_end] + build_experiments() + data[root_end:]

open(p, "wb").write(data)
print("  experiments.gametest = 1")
PY

say "done. upload pack and restart bds."
cat <<'EOF'
Verify once BDS is up:
  docker compose logs -f bds | grep '\[tgbridge\]'
Expected:
  [tgbridge] chat=-100... bot=✓ api=https://api.telegram.org
EOF
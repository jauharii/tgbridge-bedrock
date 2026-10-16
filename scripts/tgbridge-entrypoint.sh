#!/bin/bash
# tgbridge-entrypoint.sh — runs BEFORE the upstream itzg bedrock entrypoint.
#
# Installs the behavior pack + config from env vars, enables the Beta APIs
# experiment, then hands off to the untouched upstream entrypoint.
#
# WHY THE PRIMING PASS: Bedrock has no server.properties toggle for experiments
# (itzg's property-definitions.json has 63 properties, none of them experiments),
# and BDS CREATES level.dat itself on a brand-new world. So on a fresh install
# there is no level.dat to patch before the server boots — and the pack's scripts
# are loaded at world load, i.e. too late to patch afterwards.
#
# Fix: when beta-apis is not yet enabled, start the server once in a "priming"
# pass, wait for BDS to create level.dat, patch it, stop that pass cleanly, then
# start the real server. That is one extra boot on a fresh install, once ever.
#
# Env:
#   TG_CHAT_ID         (required) telegram chat id, e.g. -1001234567890
#   TG_TOKEN           (required) bot token
#   TG_API_BASE        default https://api.telegram.org (self-hosted bot api)
#   TG_POLL_BACKOFF_MS default 3000
#   TG_BATCH_SIZE      default 8
#   TG_BATCH_FLUSH_MS  default 4000
#   LEVEL_NAME         upstream world dir name (default "world")
#   TG_PRIMING_WAIT_S  how long to wait for level.dat during priming (default 120)
set -eo pipefail

HEADER_UUID=$(python3 -c 'import json;print(json.load(open("/opt/tgbridge-pack/manifest.json"))["header"]["uuid"])')
MODULE_UUID=$(python3 -c 'import json;print(json.load(open("/opt/tgbridge-pack/manifest.json"))["modules"][0]["uuid"])')
LEVEL="${LEVEL_NAME:-world}"
WORLD_DIR="/data/worlds/$LEVEL"

log() { echo "[tgbridge-install] $*"; }
fail_if_unconfigured() {
  if [ -z "${TG_CHAT_ID:-}" ] || [ -z "${TG_TOKEN:-}" ]; then
    log "TG_CHAT_ID / TG_TOKEN unset — bridge will stay idle (server starts anyway)"
  fi
}

# ── 1. pack ──────────────────────────────────────────────────────────────────
mkdir -p "/data/behavior_packs/$HEADER_UUID"
cp -a /opt/tgbridge-pack/. "/data/behavior_packs/$HEADER_UUID/"
log "pack installed (uuid $HEADER_UUID)"

# ── 2. variables.json (only when configured; never clobber with empty values) ──
if [ -n "${TG_CHAT_ID:-}" ] && [ -n "${TG_TOKEN:-}" ]; then
  mkdir -p /data/config/default
  python3 - <<'PY'
import json, os
path = "/data/config/default/variables.json"
att = {
    "chat": int(os.environ["TG_CHAT_ID"]),
    "token": os.environ["TG_TOKEN"],
    "polling": {"backoffMs": int(os.environ.get("TG_POLL_BACKOFF_MS", "3000"))},
    "batching": {"size": int(os.environ.get("TG_BATCH_SIZE", "8")),
                 "timeoutMs": int(os.environ.get("TG_BATCH_FLUSH_MS", "4000"))},
}
cur = {}
if os.path.exists(path):
    try:
        cur = json.load(open(path))
    except Exception:
        cur = {}
cur.update({"PAPI": os.environ.get("TG_API_BASE", "https://api.telegram.org"),
            "PATT": json.dumps(att)})
tmp = path + ".tmp"
json.dump(cur, open(tmp, "w"), indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("ok")
PY
  log "variables.json written (0600)"
else
  fail_if_unconfigured
fi

# ── 3. per-module permissions (this is what allows @minecraft/server-net) ─────
mkdir -p "/data/config/$MODULE_UUID"
cat > "/data/config/$MODULE_UUID/permissions.json" <<'JSON'
{ "allowed_modules": ["@minecraft/server", "@minecraft/server-net", "@minecraft/server-admin"] }
JSON
log "permissions.json written (server-net allowed)"

# ── 4. world registration ────────────────────────────────────────────────────
mkdir -p "$WORLD_DIR"
python3 - "$WORLD_DIR/world_behavior_packs.json" "$HEADER_UUID" <<'PY'
import json, os, sys
path, uuid = sys.argv[1], sys.argv[2]
data = []
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = []
data = [e for e in data if e.get("pack_id") != uuid]
data.append({"pack_id": uuid, "version": [0, 1, 0]})
tmp = path + ".tmp"
json.dump(data, open(tmp, "w"), indent=2)
os.replace(tmp, path)
print("ok (%d pack(s))" % len(data))
PY
log "world_behavior_packs.json: registered"

# ── 5. beta-apis ─────────────────────────────────────────────────────────────
# Beta APIs needs THREE experiment flags set, not just gametest: BDS otherwise
# reports "requesting dependency on beta APIs ... but the Beta APIs experiment is
# not enabled" (verified against BDS 1.26.52, and itzg discussion #442 tells
# operators to set the two bookkeeping flags alongside the feature flag).
beta_apis_enabled() {
  [ -f "$WORLD_DIR/level.dat" ] || return 1
  for flag in gametest experiments_ever_used saved_with_toggled_experiments; do
    grep -q "$flag" "$WORLD_DIR/level.dat" || return 1
  done
  return 0
}

if beta_apis_enabled; then
  log "beta-apis flags present in level.dat — starting server"
  log "NOTE: on BDS 1.26+ these level.dat flags may be ignored (world data lives in worlds/$LEVEL/db). If the log later says 'the Beta APIs experiment is not enabled', see README 'Known blocker'."
else
  # Priming pass: let BDS create the world, patch, stop, then boot for real.
  log "beta-apis not enabled yet — priming pass (one extra boot, once)"
  /opt/demoter-entry.sh "$@" &
  server_pid=$!
  trap 'kill -TERM "$server_pid" 2>/dev/null || true' TERM INT

  waited=0
  limit="${TG_PRIMING_WAIT_S:-120}"
  while [ "$waited" -lt "$limit" ]; do
    if [ -f "$WORLD_DIR/level.dat" ]; then
      # BDS writes level.dat; give it a moment to finish writing before patching
      sleep 3
      python3 /opt/tgbridge-patch-level-dat.py "$WORLD_DIR/level.dat" || true
      if beta_apis_enabled; then
        log "beta-apis flags written — restarting server"
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        trap - TERM INT
        exec /opt/demoter-entry.sh "$@"
      fi
    fi
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 2
    waited=$((waited + 2))
  done
  trap - TERM INT
  log "priming pass ended without patching — continuing (restart the server to retry)"
  wait "$server_pid" 2>/dev/null || true
  exit 0
fi

# ── 6. hand off to upstream ──────────────────────────────────────────────────
exec /opt/demoter-entry.sh "$@"
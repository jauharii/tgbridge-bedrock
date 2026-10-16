# tgbridge-bedrock — port of vanutp/tgbridge to a Bedrock behavior pack

Java tgbridge (Paper plugin) ported to Bedrock Dedicated Server as a **behavior pack
(script API addon)**. Bridges your Telegram group and Minecraft chat both directions.

## Why a port, not the Java plugin

Java plugins cannot run on Bedrock Dedicated Server. A cross-play server
(Paper/Purpur + Geyser cross-play) can use the Java tgbridge for everyone; a **pure BDS**
server — including the Bedrock client connecting straight to a BDS — needs the
bridge in BDS script API form instead. No upstream BDS behavior pack exists
(checked Modrinth, CurseForge, GitHub, MCPEDL — the closest, BedrockBridge, is
Discord-only).

## What it does (parity slice from the Java tgbridge feature set)

| Java tgbridge feature | This port |
|---|---|
| MC chat → TG | ✅ (batched up to 8 msgs / 4s) |
| join/leave → TG | ✅ |
| TG → MC chat | ✅ (rendered as `<name> > message`, group chats only) |
| `/list` from TG | ✅ |
| death/close messages | ❌ not in v0.1 (BDS has no death event carrying the inventory) |
| advancements | ❌ same |
| media from TG → MC | ✅ as `[photo] <caption>` |
| multiple chats | ❌ one chat per server |
| replacements.json | ❌ not in v0.1 |
| Java `/tgbridge` in-game command | ❌ (restart = reload) |

## Install (any BDS with file access)

```bash
git clone https://github.com/jauharii/tgbridge-bedrock && cd tgbridge-bedrock
export CHAT_ID="-1001234567890"        # your group chat id
export TOKEN="123456:AB-Cdef..."        # your bot token
./install.sh /path/to/your/bds/data
LEVEL=myworld ./install.sh /path/to/bds/data   # if the world dir isn't named 'world'
```

Then restart the BDS. Look in the log for:

```
[tgbridge] chat=-1001234567890 bot=✓ api=https://api.telegram.org
```

Anything else means the config is incomplete; the pack runs a poll but sends
nothing unless both the chat id and the token resolve.

## How the token + chat are configured

BDS reads config from `config/default/variables.json` at world load:

```json
{
  "PAPI": "https://api.telegram.org",
  "PATT": "{\"chat\": -1001234567890, \"token\": \"123456:AB-Cdef...\"}"
}
```

`PAPI` optional (self-hosted bot api server). `PATT` is a quoted JSON **string** that
unzips to `{chat, token, batching?, polling?, messages?}` — same shape as the Java
tgbridge's `config.yml` keys mashed into one value because BDS variables.json is
flat. Install.sh writes it from `CHAT_ID` + `TOKEN` env vars.

**Why the token is a variable, not a `SecretString`:** Telegram auth lives in the URL
(`/bot<TOKEN>/method`), and Bedrock's SecretString can only appear inside an
`HttpHeader` value (verified on learn.microsoft.com docs). URL-splicing it is
impossible by design. Plaintext in `variables.json` is the same posture the Java
tgbridge uses (`config.yml`), and any leak shows up in the BDS world folder, not in a
zip you might share.

## ⚠ Known blocker: Beta APIs is NOT enabled by this repo on BDS 1.26+

Everything in this repo is tested and working **except** the last mile: making
`@minecraft/server-net` load. On BDS 1.26.52 the pack loads into the world but
its scripts are refused, every boot:

```
[Scripting] Plugin [tgbridge Bedrock - 0.1.0] - requesting dependency on beta APIs
[@minecraft/server-net - 1.0.0-beta], but the Beta APIs experiment is not enabled.
```

### What was measured (not assumed)

| Attempt | Result |
|---|---|
| Set `experiments.gametest=1` in `level.dat` (little-endian NBT, correct root offset) | refused |
| Also set `experiments_ever_used=1` + `saved_with_toggled_experiments=1` (the three flags itzg discussion #442 tells operators to set) | refused |
| Patch while the server is **stopped**, then boot once | refused |
| `experimental-gameplay=true` in `server.properties` | refused (BDS has no such property; 63 properties checked in itzg's definitions, none for experiments) |
| `BETA_APIS=true` / `ALLOW_OUTBOUND_SCRIPT_DEBUGGING=true` env | refused (not real properties) |
| Flags survive a clean BDS shutdown (they are not being overwritten) | confirmed |

### The likely reason

BDS 1.26 logs `Opening level 'worlds/world/db'` and stores world data in a
**LevelDB** directory (`worlds/<world>/db/*.ldb`, snappy-compressed), and
`level.dat`'s mtime stops changing after the world is migrated. So on this
version the experiment flags appear to be read from the LevelDB, not from
`level.dat` — which makes a byte-level `level.dat` patch ineffective.

### What to try next

- Write the flags into the LevelDB (needs a LevelDB writer that speaks Bedrock's
  snappy-compressed table format).
- Or enable Beta APIs once in the **Bedrock client** on a copy of the world
  (Settings → Experiments → Beta APIs) and upload that world to the server — the
  documented workaround in itzg discussion #373.
- Or pin a BDS version where `level.dat` is still authoritative (all the
  `1.21.x` downloads 404 from Mojang as of 2026-10-16, so this needs checking).

Until then, `pack/` is verified-good (unit tests, syntax, manifest, deterministic
mcpack) and the container half of the install works: the pack is copied, the
world registration is written, `variables.json` and `permissions.json` are
created, and no manual steps are needed to get there.

## Declarative compose (recommended)

Everything lives in `docker-compose.yml` + `.env`; the image does the install at boot:

```bash
git clone https://github.com/jauharii/tgbridge-bedrock && cd tgbridge-bedrock
cp .env.example .env && $EDITOR .env       # chat id + bot token
docker compose up -d --build
docker compose logs -f | grep '\[tgbridge\]'
```

The Dockerfile extends `itzg/minecraft-bedrock-server` and adds an entrypoint that
copies the pack, writes `variables.json` from `TG_CHAT_ID`/`TG_TOKEN` (mode 0600),
grants `@minecraft/server-net` via `permissions.json`, registers the pack in the
world, and patches the Beta APIs experiment flags into `level.dat` — including the
fresh-world case, where it primes once (boot → wait for `level.dat` → patch →
stop → boot again) so no manual step is needed.

**Caveat:** the `level.dat` patch is verified to write the right bytes but does
*not* enable Beta APIs on BDS 1.26+ (see "Known blocker" above). Everything else
in this flow does work.

`test/entrypoint-test.sh` exercises the whole flow against a fake server boot;
run it before any change (`ALL PASS` = good).

## Install into a host-mounted BDS data dir (no image build)

`install-itzg.sh` writes the pack + config straight into a host-mounted BDS data
directory, in exactly the layout the itzg image reads at boot. It is idempotent
and preserves any existing `experiments` flags in `level.dat`.

```bash
export CHAT_ID="-1001234567890" TOKEN="123456:AB-Cdef..."
./install-itzg.sh ./bds/data
```

What it writes (same PAPI/PATT layout the image's own `VARIABLES` env produces):

```
./data/behavior_packs/<header-uuid>/{manifest.json,scripts/*.js,pack_icon.png}
./data/config/default/variables.json                     <- PAPI + PATT{chat,token}
./data/config/<module-uuid>/permissions.json             <- grants @minecraft/server-net
./data/worlds/<level>/world_behavior_packs.json          <- registers header uuid
./data/worlds/<level>/level.dat                          <- sets the 3 beta-apis flags (merges)
```

Restart = re-deploy. Want a different world name? `LEVEL=myworld ./install-itzg.sh ./data`.

Named docker volumes (not bind mounts) need the pack copied in via a helper container
(`docker run --rm -v bds-data:/data -v ./pack:/pack alpine cp -a /pack/. /data/behavior_packs/<uuid>/`)
— beyond what this script targets.

## Verifying

```bash
./verify.sh                  # syntax, unit tests, manifest, deterministic mcpack, entrypoint flow
node test/lib.test.mjs       # unit tests on pure funcs
node test/config.test.mjs    # unit tests on config normalizing
bash test/entrypoint-test.sh # full install flow against a fake BDS boot
```

After install + restart, in-game type `hello` and watch the group. If nothing lands,
check the log for `[tgbridge] chat=… bot=✓` first, then whether Beta APIs is enabled.

## Known limits

- Requires BDS **and** the Beta APIs experiment; `@minecraft/server-net` is
  BDS-only, so this pack cannot run in singleplayer or Realms (which is also why
  there is no packaged `.mcaddon` — it would be a silent no-op).
- No in-game reload command (restart the server instead).
- One chat per server, and topics are not filtered: every message in the group
  reaches MC chat. Ponytail: add `topicId` to PATT and compare `message_thread_id`
  if that matters later.

## The 409 rule (read this if polls spin forever)

Telegram allows exactly **one** `getUpdates` consumer per bot token. If another
bridge (for example the Java tgbridge plugin on a cross-play server) is polling
the same token, this pack gets `409 Conflict` forever. The pack treats 409 as
FATAL and logs:

```
[tgbridge] 409 = another getUpdates consumer already owns this bot token (usually the Java tgbridge). STOPPED. Give this pack its OWN bot token, or remove the other consumer.
```

Fixes: (a) remove the other consumer, or (b) create a second bot via @BotFather and
put its token in `TG_TOKEN`/`PATT`. Sending (`sendMessage`) works from either side;
only the update-polling slot is exclusive.

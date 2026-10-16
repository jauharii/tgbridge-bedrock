# tgbridge-bedrock — drop-in image.
#
# Extends the upstream itzg/minecraft-bedrock-server. At container start it:
#   1. copies the behavior pack into /data/behavior_packs/<uuid>/
#   2. writes /data/config/default/variables.json      (PAPI + PATT{chat,token})
#   3. writes /data/config/<uuid>/permissions.json      (allows @minecraft/server-net)
#   4. registers the pack in worlds/$LEVEL_NAME/world_behavior_packs.json
#   5. enables the Beta APIs experiment in worlds/$LEVEL_NAME/level.dat
#   6. execs the upstream entrypoint, behaviour otherwise unchanged
#
# The upstream image ships curl/openssl/unzip/jq but NOT python, and the level.dat
# experiment flag is binary NBT — so python3 is added here rather than pretending
# bash can do it.
FROM itzg/minecraft-bedrock-server

USER root
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-minimal \
    && rm -rf /var/lib/apt/lists/*

COPY pack /opt/tgbridge-pack
COPY --chmod=755 scripts/tgbridge-entrypoint.sh /opt/tgbridge-entrypoint.sh
COPY --chmod=755 scripts/patch-level-dat.py /opt/tgbridge-patch-level-dat.py

ENV TG_API_BASE="https://api.telegram.org" \
    TG_POLL_BACKOFF_MS=3000 \
    TG_BATCH_SIZE=8 \
    TG_BATCH_FLUSH_MS=4000 \
    TG_PRIMING_WAIT_S=120

ENTRYPOINT ["/opt/tgbridge-entrypoint.sh"]
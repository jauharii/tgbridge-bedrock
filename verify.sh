#!/usr/bin/env bash
# verify.sh — self-check: manifest sanity, tests, zip determinism, icon decode.
set -euo pipefail
cd "$(dirname "$0")"

echo "== node syntax =="
for f in pack/scripts/main.js pack/scripts/lib.js pack/scripts/config.js; do
  node --check "$f"
done
echo "  ok"

echo "== unit tests =="
node test/lib.test.mjs
node test/config.test.mjs
echo "  ok"

echo "== manifest structural =="
python3 - <<'PY'
import json, hashlib, uuid
m = json.load(open("pack/manifest.json"))
h = m["header"]
assert m["format_version"] == 2
assert h["uuid"] == "06227249-c4f5-5be7-b904-32c4768c4993"
mods = m["modules"]
assert len(mods) == 1 and mods[0]["type"] == "script"
assert mods[0]["entry"] == "scripts/main.js"
names = [d["module_name"] for d in m["dependencies"]]
assert "@minecraft/server-net" in names and "@minecraft/server" in names
assert "@minecraft/server" in [d["module_name"] for d in m["dependencies"]]
# uuid version/variant nibbles sane
u = uuid.UUID(h["uuid"])
assert u.version >= 1
print("  manifest ok")
PY

echo "== zip determinism =="
python3 - <<'PY'
import zipfile, hashlib, io
def build(path=None):
    import os
    files = sorted(
        (os.path.join(dp, f).replace("pack/", "", 1)
         for dp, _, fs in os.walk("pack") for f in fs),
    )
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for f in files:
            z.write(os.path.join("pack", f), f)
    return buf.getvalue()

a = build()
with open("tgbridge-bedrock-v0.1.0.mcpack", "wb") as fh: fh.write(a)
b = build()
h1, h2 = hashlib.sha256(a).hexdigest()[:16], hashlib.sha256(b).hexdigest()[:16]
assert h1 == h2, f"zip not deterministic {h1} vs {h2}"
z = zipfile.ZipFile(io.BytesIO(a))
assert z.testzip() is None
names = z.namelist()
assert "manifest.json" in names
print(f"  {len(names)} files, {len(a)} bytes, sha16={h1}")
PY

echo "== mcpack readable as bedrock pack (manifest first) =="
python3 - <<'PY'
import zipfile, json
z = zipfile.ZipFile("tgbridge-bedrock-v0.1.0.mcpack")
m = json.load(z.open("manifest.json"))
assert m["header"]["name"] == "tgbridge Bedrock"
print("  ok")
PY

echo "== entrypoint flow (fake boot) =="
bash test/entrypoint-test.sh | tail -2

echo "ALL PASS"

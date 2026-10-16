#!/usr/bin/env python3
"""Enable the Beta APIs experiment in a Bedrock level.dat.

Sets the three experiment flags BDS requires for Beta APIs inside the world's
level.dat, MERGING (never replacing) any experiments already there.

Why a byte-level patch: Bedrock has NO server.properties toggle for experiments.
Java's `initial-enabled-packs` does not exist in Bedrock's properties, and itzg's
image exposes no such property either (all 63 entries in its
property-definitions.json were checked), so on a dedicated server the flag only
exists in the world's level.dat.

NBT FORMAT (measured on a real BDS 1.26.52 level.dat, not assumed):
  * Little-endian, unlike Java's big-endian.
  * The ROOT compound's name length is 4 bytes; inner tag name lengths are 2
    bytes. This asymmetry is the whole reason a "looks right" parser silently
    finds zero top-level tags.
    Real file head: 0a 00 00 00 | b7 0b 00 00 | 0a 00 00 08 ...
                     ^root  ^root name len (4B = empty)   ^nested compound
  * Tag types include 0=end, 1=byte, 2=short, 3=int, 4=long, 5=float, 6=double,
    7=byte array, 8=string, 9=list, 10=compound.
"""
import struct
import sys

TAG_END, TAG_BYTE, TAG_COMPOUND = 0, 1, 10
E = "<"  # little-endian: Bedrock NBT


def rd_name(b, i, width):
    n = struct.unpack_from(E + ("I" if width == 4 else "H"), b, i)[0]
    i += width
    if n == 0:
        return "", i
    return b[i:i + n].decode("utf-8", "replace"), i + n


def skip_payload(b, t, i):
    if t == 1:
        return i + 1
    if t == 2:
        return i + 2
    if t == 3:
        return i + 4
    if t == 4:
        return i + 8
    if t == 5:
        return i + 4
    if t == 6:
        return i + 8
    if t == 7:
        return i + struct.unpack_from(E + "i", b, i)[0]
    if t == 8:
        n = struct.unpack_from(E + "H", b, i)[0]
        return i + 2 + n
    if t == 9:  # list: element type + int32 count
        et = b[i]
        n = struct.unpack_from(E + "i", b, i + 1)[0]
        j = i + 5
        for _ in range(max(n, 0)):
            j = skip_payload(b, et, j)
        return j
    if t == TAG_COMPOUND:
        while True:
            if b[i] == TAG_END:
                return i + 1
            t2 = b[i]
            i += 1
            _, i = rd_name(b, i, 2)
            i = skip_payload(b, t2, i)
    raise ValueError(f"unhandled NBT tag type {t}")


def _iter_byte_tags(compound_payload: bytes):
    """Yield (name, raw_tag_bytes) for each tag inside a compound payload."""
    i = 0
    while i < len(compound_payload) and compound_payload[i] != TAG_END:
        t = compound_payload[i]
        start = i
        i += 1
        nm, i = rd_name(compound_payload, i, 2)
        i = skip_payload(compound_payload, t, i)
        yield nm, bytes(compound_payload[start:i])


REQUIRED = (b"gametest", b"experiments_ever_used", b"saved_with_toggled_experiments")


def build_experiments(existing: bytes) -> bytes:
    """A complete `experiments` compound.

    Beta APIs (the gametest flag) is NOT enough on a dedicated server: BDS also
    requires the two companion bookkeeping flags to be 1, which is exactly what
    the in-game experiments screen sets and what itzg's own WorldEdit thread
    instructs operators to hand-edit (discussion #442). Setting only gametest
    yields, verbatim from BDS:
        [Scripting][error]-Plugin [...] - requesting dependency on beta APIs
        [@minecraft/server-net - 1.0.0-beta], but the Beta APIs experiment is not enabled.

    Unrelated flags in the existing compound are copied verbatim.
    """
    out = bytearray()
    out += bytes([TAG_COMPOUND])
    name = b"experiments"
    out += struct.pack(E + "H", len(name)) + name
    present = set()
    for nm, raw in _iter_byte_tags(existing):
        if nm.encode() in REQUIRED:
            out += bytes([TAG_BYTE]) + struct.pack(E + "H", len(nm)) + nm.encode() + b"\x01"
            present.add(nm.encode())
        else:
            out += raw
    for tag in REQUIRED:
        if tag not in present:
            out += bytes([TAG_BYTE]) + struct.pack(E + "H", len(tag)) + tag + b"\x01"
    out += bytes([TAG_END])
    return bytes(out)


def _walk_ok(data: bytes, start: int) -> bool:
    """True when a top-level tag walk starting at `start` consumes the file
    exactly and lands on the final TAG_END. Used to find the real payload offset
    without hardcoding a format I have not verified."""
    i = start
    try:
        while i < len(data) and data[i] != TAG_END:
            t = data[i]
            i += 1
            _, i = rd_name(data, i, 2)
            i = skip_payload(data, t, i)
    except Exception:
        return False
    return i == len(data) - 1


def _top_tags(data: bytes, start: int):
    i = start
    while i < len(data) and data[i] != TAG_END:
        t = data[i]
        i += 1
        nm, i = rd_name(data, i, 2)
        yield t, nm, i
        i = skip_payload(data, t, i)


def patch_level_dat(path: str) -> str:
    data = bytearray(open(path, "rb").read())
    if len(data) < 8 or data[0] != TAG_COMPOUND:
        return "skip (not a little-endian NBT compound root)"

    # Locate the root payload empirically: the header length differs between
    # writers, so probe a small window and accept only the offset where the whole
    # file parses and ends exactly on its final TAG_END.
    payload_start = None
    for cand in range(2, 16):
        if _walk_ok(bytes(data), cand):
            payload_start = cand
            break
    if payload_start is None:
        return "skip (could not locate root payload; format unrecognised)"

    for t, nm, i in _top_tags(bytes(data), payload_start):
        if nm != "experiments":
            continue
        payload_end = skip_payload(bytes(data), t, i)
        tag_start = i - (1 + 2 + len(nm))
        existing = bytes(data[i:payload_end - 1])
        new = build_experiments(existing)
        replacement = data[:tag_start] + new + data[payload_end:]
        if bytes(replacement) == bytes(data):
            return "ok (beta-apis flags already set)"
        kept = [n for n, _ in _iter_byte_tags(existing)
                if n.encode() not in REQUIRED]
        open(path, "wb").write(replacement)
        return f"ok (3 beta-apis flags set, kept {len(kept)} unrelated flag(s))"

    # No experiments compound anywhere: append one before the root TAG_END.
    # A root length field, when present, must be updated too.
    root_end = len(data) - 1
    if data[root_end] != TAG_END:
        return "skip (unexpected level.dat shape)"
    addition = build_experiments(b"")
    # detect and fix an explicit root payload length (little-endian u32 at
    # offset 4 is what real BDS writes; only patch it if it already matched)
    try:
        declared = struct.unpack_from(E + "I", data, 4)[0]
        if declared == root_end - payload_start:
            struct.pack_into(E + "I", data, 4, declared + len(addition))
    except Exception:
        pass
    data = data[:root_end] + addition + data[root_end:]
    open(path, "wb").write(data)
    return "ok (experiments compound created)"


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: patch-level-dat.py <level.dat>", file=sys.stderr)
        sys.exit(2)
    try:
        print("[tgbridge] beta-apis: " + patch_level_dat(sys.argv[1]))
    except Exception as exc:
        # never block the server from starting; report loudly instead
        print(f"[tgbridge] beta-apis: FAILED ({exc}) -- pack scripts will not load", file=sys.stderr)
        sys.exit(0)
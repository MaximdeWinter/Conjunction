"""The game's .w3speech files (spoken lines: audio + mouth movement) - read v162 / v163 / v164, write v164.

Layout (WolvenKit-7's coder; v164 measured against the v163 backup, 30.09.2026):
    "CPSW", version u32, key1 u16, count (bit6)
    per line: id ^ magic u32, id_high u32, audio offset u64 (points at the audio's size field), audio size + 12 u64,
              lipsync offset u64, lipsync size u64
    key2 u16
    per line: audio size u32, audio (a wem), duration f32, a u32 (v162 / v163: 4, v164: 1), lipsync
The game's lipsync is a compact animation (fps, duration, tracks); radish's tools write a CR2W (CSkeletalAnimation)
there instead.
"""
import struct

from .w3strings import LANGS, _bit6_read, _bit6_write


def read(data):
    """-> (version, lang, [(id, audio bytes, duration, lipsync bytes)])."""
    if data[:4] != b"CPSW":
        raise ValueError("not a .w3speech file")
    version = struct.unpack_from("<I", data, 4)[0]
    key1 = struct.unpack_from("<H", data, 8)[0]
    count, i = _bit6_read(data, 10)
    rows = [struct.unpack_from("<IIQQQQ", data, i + 40 * k) for k in range(count)]
    key2 = struct.unpack_from("<H", data, i + 40 * count)[0]
    lang = next((lg for lg, (k1, k2, _m) in LANGS.items() if (k1, k2) == (key1, key2)), "en")
    magic = LANGS[lang][2]
    out = []
    for lid, _high, woff, wsz, coff, csz in rows:
        audio = data[woff + 4:woff + 4 + wsz - 12]
        duration = struct.unpack_from("<f", data, woff + 4 + wsz - 12)[0]
        out.append((lid ^ magic, audio, duration, data[coff:coff + csz]))
    return version, lang, out


def write_v164(lang, lines, lipsync=True):
    """[(id, audio, duration, lipsync)] -> a v164 file (lipsync False: no mouth movement - an empty lipsync)."""
    key1, key2, magic = LANGS[lang]
    # the game looks lines up by binary search over the stored (keyed) ids: sorted per language, as its own files
    lines = sorted(lines, key=lambda ln: ln[0] ^ magic)
    head = b"CPSW" + struct.pack("<IH", 164, key1) + _bit6_write(len(lines))
    pos = len(head) + 40 * len(lines) + 2
    rows, body = bytearray(), bytearray()
    for sid, audio, duration, lips in lines:
        lips = lips if lipsync else b""
        woff = pos
        chunk = struct.pack("<I", len(audio)) + audio + struct.pack("<fI", duration, 1)
        coff = pos + len(chunk)
        rows += struct.pack("<IIQQQQ", sid ^ magic, 0, woff, len(audio) + 12, coff, len(lips))
        body += chunk + lips
        pos += len(chunk) + len(lips)
    return head + bytes(rows) + struct.pack("<H", key2) + bytes(body)

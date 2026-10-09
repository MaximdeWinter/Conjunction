"""The game's .w3strings files - read v162 / v163 / v164, write v164 (the remaster's; radish writes v162, which the
remaster no longer loads - measured 30.09.2026: a DLC's v162 strings come back empty from GetLocStringById).

Layout (WolvenKit-7's reader, v164 measured against the v163 backup):
    "RTSW", version u32, key1 u16
    block 1: count (bit6), per string: id ^ magic u32, offset u32, length u32 - sorted by id ^ magic
    block 2: count (bit6), per key: hash of the key text u32, id ^ magic u32 - sorted by the hash
    block 3: count (bit6) = the text's size, then the text
    key2 u16
v162 / v163: the text is utf-16, offset and length in characters, each character XORed with a key that walks on.
v164: the text is utf-8, offset and length in bytes, each string ended by one 0 byte; each byte XORed with the low
byte of the same walking key.
"""
import struct

LANGS = {  # language -> (key1, key2, magic)
    "ar": (0, 0, 0), "br": (0, 0, 0), "esmx": (0, 0, 0), "kr": (0, 0, 0), "tr": (0, 0, 0),
    "cn": (0, 0, 0), "ua": (0, 0, 0),                     # the remaster's newer ones: no key (its files, 30.09.)
    "pl": (0x8349, 0x6237, 0x73946816), "en": (0x4397, 0x5139, 0x79321793), "de": (0x7588, 0x6138, 0x42791159),
    "it": (0x4593, 0x1894, 0x12375973), "fr": (0x2386, 0x3176, 0x75921975), "cz": (0x2498, 0x7354, 0x21793217),
    "es": (0x1879, 0x6651, 0x42387566), "zh": (0x1863, 0x2176, 0x16875467), "ru": (0x6348, 0x1486, 0x42386347),
    "hu": (0x4237, 0x8932, 0x67823218), "jp": (0x5483, 0x4893, 0x59825646),
}   # WolvenKit-7 W3Language.cs


def _bit6_read(d, i):
    result, shift, k = 0, 0, 1
    while True:
        b = d[i]
        i += 1
        s, mask = 6, 255
        if b > 127:
            mask, s = 127, 7
        elif b > 63 and k == 1:
            mask = 63
        result |= (b & mask) << shift
        shift += s
        k += 1
        if b < 64 or (k >= 3 and b < 128):
            return result, i


def _bit6_write(v):
    """The inverse of _bit6_read: 6 bits in the first byte (0x40: more follows), then 7 bits a byte (0x80: more)."""
    out = bytearray()
    first = v & 0x3F
    v >>= 6
    if v:
        first |= 0x40
    out.append(first)
    while v:
        b = v & 0x7F
        v >>= 7
        if v:
            b |= 0x80
        out.append(b)
    return bytes(out)


def _keys(magic, length):
    """The walking key: one value a character (v162/163) or a byte (v164)."""
    sk = (magic >> 8) & 0xFFFF
    for _ in range(length):
        yield ((length + 1) * sk) & 0xFFFF
        sk = ((sk << 1) | (sk >> 15)) & 0xFFFF


def lang_of(key1, key2):
    return next((lang for lang, (k1, k2, _m) in LANGS.items() if (k1, k2) == (key1, key2)), None)


def read(data, lang=None):
    """-> (version, lang, {id: text}, {id: key text hash})."""
    if data[:4] != b"RTSW":
        raise ValueError("not a .w3strings file")
    version = struct.unpack_from("<I", data, 4)[0]
    key1, key2 = struct.unpack_from("<H", data, 8)[0], struct.unpack_from("<H", data, len(data) - 2)[0]
    lang = lang or lang_of(key1, key2)
    magic = LANGS[lang][2] if lang in LANGS else 0
    n1, i = _bit6_read(data, 10)
    entries = [struct.unpack_from("<III", data, i + 12 * k) for k in range(n1)]
    i += 12 * n1
    n2, i = _bit6_read(data, i)
    keys = {}
    for k in range(n2):
        h, sid = struct.unpack_from("<II", data, i + 8 * k)
        keys[sid ^ magic] = h
    i += 8 * n2
    _n3, start = _bit6_read(data, i)
    texts = {}
    for hid, off, ln in entries:
        if version >= 164:
            raw = data[start + off:start + off + ln]
            texts[hid ^ magic] = bytes(b ^ (k & 0xFF) for b, k in zip(raw, _keys(magic, ln))).decode("utf-8",
                                                                                                  "replace")
        else:
            p, chars = start + off * 2, []
            for k in _keys(magic, ln):
                chars.append(chr((data[p] ^ (k & 0xFF)) | ((data[p + 1] ^ (k >> 8)) << 8)))
                p += 2
            texts[hid ^ magic] = "".join(chars)
    return version, lang, texts, keys


def key_hash(text):
    """A string key's hash as the game looks it up: of the key in lower case (a mod's 'preset_value_ExAr_x' is
    stored as the hash of 'preset_value_exar_x')."""
    h = 0
    for c in text.lower():
        h = (h * 31 + ord(c)) & 0xFFFFFFFF
    return h


def write_v164(lang, texts, keys=None, hashes=None):
    """{id: text} (+ {id: key text} - the strings found by name - or {id: its hash}, as read) -> a v164 file."""
    lang = lang.lower()
    key1, key2, magic = LANGS[lang]
    order = sorted(texts, key=lambda sid: sid ^ magic)
    blob, table = bytearray(), []
    for sid in order:
        raw = texts[sid].encode("utf-8")
        table.append((sid ^ magic, len(blob), len(raw)))
        blob += bytes(b ^ (k & 0xFF) for b, k in zip(raw, _keys(magic, len(raw)))) + bytes(1)
    out = bytearray(b"RTSW") + struct.pack("<IH", 164, key1)
    out += _bit6_write(len(table))
    for row in table:
        out += struct.pack("<III", *row)
    hashed = dict(hashes or {})
    hashed.update({sid: key_hash(k) for sid, k in (keys or {}).items() if k})
    pairs = sorted(((h, sid ^ magic) for sid, h in hashed.items()), key=lambda p: p[0])
    out += _bit6_write(len(pairs))
    for h, hid in pairs:
        out += struct.pack("<II", h, hid)
    out += _bit6_write(len(blob)) + blob + struct.pack("<H", key2)
    return bytes(out)

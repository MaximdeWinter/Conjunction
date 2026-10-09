"""Pictures out of the game's texture.cache (item icons: gameplay\\gui_new\\icons\\inventory\\...png).

Footer (last 32 bytes): crc (u64), used pages, entry count, string table size, mip table count, "HCXT", version.
Before it: the entries (52 bytes each: hash, name offset, page offset (x 4096), compressed size, size, alignment,
width, height, mips, slices, mip offset index, mip count, timestamp, type1, type2, cube, -), the names before them.
An entry's data: one piece per mip (packed size u32, size u32, mip u8, zlib); type1 7 = DXT1, 8 = DXT5,
13 = DXT3, 10 = BC7, 14 = BC4, 15 = BC5, 253 = uncompressed RGBA.
"""
import glob
import io
import os
import struct
import zlib

from . import config

# fourcc (DX10: a DXGI format follows the header), bytes per 4x4 block, DXGI format; 10 BC7, 14 BC4, 15 BC5 are the
# remaster's (checked 29.09. by decoding one of each)
FORMATS = {7: (b"DXT1", 8, 0), 8: (b"DXT5", 16, 0), 13: (b"DXT3", 16, 0), 10: (b"DX10", 16, 98),
           14: (b"ATI1", 8, 0), 15: (b"ATI2", 16, 0)}


class TextureCache:
    def __init__(self, game=None):
        game = game or config.load()["game"]
        self.files = sorted(glob.glob(os.path.join(game, "content", "content*", "texture.cache"))) + \
            sorted(glob.glob(os.path.join(game, "dlc", "*", "content", "texture.cache")))
        self.index = {}
        for path in self.files:
            try:
                self._read_index(path)
            except (OSError, struct.error, ValueError):
                continue

    def _read_index(self, path):
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(-32, 2)
            _crc, _pages, count, strsize, _mips, ident, _ver = struct.unpack("<QIIIIII", f.read(32))
            if ident != 0x54584348:                 # "HCXT"
                return
            entries_off = size - 32 - count * 52
            f.seek(entries_off - strsize)
            table = f.read(strsize)
            f.seek(entries_off)
            raw = f.read(count * 52)
        for i in range(count):
            e = struct.unpack_from("<IiIIIIHHHHiiqBBBB", raw, i * 52)
            o = e[1]
            name = table[o:table.index(b"\0", o)].decode("utf-8", "replace").lower()
            self.index[name] = (path, e)

    def names(self, contains=""):
        return [n for n in self.index if contains in n]

    def image(self, name, max_side=None):
        """PIL image of the top mip of a texture (max_side: the first mip not bigger than that), or None."""
        from PIL import Image
        hit = self.index.get(name.lower())
        if not hit:
            return None
        path, e = hit
        _h, _o, page, zsize, usize, _al, w, h, _mips, _sl, _mo, _mc, _ts, t1, _t2, _cube, _x = e
        with open(path, "rb") as f:
            f.seek(page * 4096)
            raw = f.read(zsize + 64)
        # the data is a row of pieces, one per mip: packed size (u32), size (u32), mip (u8), then zlib
        data, i = b"", 0
        pieces = []
        while i + 9 <= len(raw) and len(data) < usize:
            psize, size, _mip = struct.unpack_from("<IIB", raw, i)
            if psize == 0 or size == 0:
                break
            piece = zlib.decompress(raw[i + 9:i + 9 + psize])
            pieces.append(piece)
            data += piece
            i += 9 + psize
        if max_side and t1 in FORMATS and (w > max_side or h > max_side):
            # a smaller mip: pieces are the mips from the top down (each a quarter of the one before)
            k = 0
            while (w >> k) > max_side or (h >> k) > max_side:
                k += 1
            if k < len(pieces):
                w, h = max(1, w >> k), max(1, h >> k)
                data = pieces[k]
        if t1 in FORMATS:
            fourcc, block, dxgi = FORMATS[t1]
            top = max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * block
            header = struct.pack("<4sIIIIIII44sIIIIIIIIIIIII", b"DDS ", 124, 0x1007 | 0x80000, h, w, top, 0, 1,
                                 b"\0" * 44, 32, 0x4, struct.unpack("<I", fourcc)[0], 0, 0, 0, 0, 0, 0x1000,
                                 0, 0, 0, 0)
            if dxgi:
                header += struct.pack("<IIIII", dxgi, 3, 0, 1, 0)      # 2D texture, one of it
            return Image.open(io.BytesIO(header + data[:top])).convert("RGBA")
        if w * h * 4 <= len(data):                  # uncompressed
            return Image.frombytes("RGBA", (w, h), data[:w * h * 4], "raw", "BGRA")
        return None

    def icon(self, icon_path):
        """An item's icon_path ('icons/inventory/...png') -> PIL image."""
        return self.image("gameplay\\gui_new\\" + icon_path.replace("/", "\\"))

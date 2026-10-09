"""The terrain of a world: its height read from the game's cooked tiles, changed by brush strokes, written back as
cooked tiles a mod puts over the game's (Conjunction's terrain editing - Maxim 04.10.: change the height like the
common editors do).

Measured 04.10. (Novigrad):
  The world's CClipMap (in its .w2w): terrainCorner (x, y of the south-west corner), terrainSize (metres per edge),
  numTilesPerEdge, tileRes (samples per tile edge), lowestElevation / highestElevation.
  A tile: <world dir>\\terrain_tiles\\tile_<row>_x_<col>_res<tileRes>.w2ter - row from y, col from x, samples row by
  row (y), no sample shared with the neighbour (spacing = tile size / tileRes). Height = lowest + v / 65535 *
  (highest - lowest), v an u16 (Geralt's z and the sample under him: 4 cm apart).
  Cooked: a CR2W with one CTerrainTile (tileFileVersion, maxHeightValue, minHeightValue) and its data in separate
  files <tile>.<n>.buffer - heights at 1, 3, 5, 8, 11 (tileRes, /2, /4, /8, /16 per edge; each level every second
  sample of the one above), control maps (which texture where) 2, 4, 6, 9, 12, colour 7, 10, 13 (compressed).
  Heights and control maps are byte for byte the uncooked REDkit depot's. The buffer table holds crc32 of each
  buffer, the tables and the header have their own crc (cr2w.py).

    t = Terrain("novigrad")
    t.height(x, y)                       metres at a world point
    t.apply(strokes)                     brush strokes, in order -> the tiles they touched
    t.write(out_dir)                     the touched tiles, cooked, under out_dir (depot paths)

A stroke: {"op", "x", "y", "radius", "strength", optional "shape": "circle" | "square", "falloff": "smooth" |
"linear" | "hard"} - the brush's weight 1 at the centre, 0 at its edge (smooth: a soft S, linear: a cone, hard: 1
inside). The ops (the usual set of terrain editors):
  raise / lower   up / down by `strength` metres at the centre
  smooth          towards the 3 x 3 neighbours' mean, `strength` 0..1
  flatten         towards `height` (metres; the centre's height when left out), `strength` 0..1
  set             exactly `height` (the weight only blends the edge)
  ramp            from (x, y) to ("x2", "y2"), `radius` = half its width: a straight slope from "height" to
                  "height2" (each the ground's there when left out), `strength` 0..1
  noise           rough ground: up and down by up to `strength` metres, bumps of "scale" metres (default 4),
                  "seed" for another pattern
  terrace         steps of "step" metres (default 1), `strength` 0..1
"""
import math
import os
import struct
import zlib

from . import bundles, project
from .cr2w import CR2W

HEIGHT_BUFFERS = (1, 3, 5, 8, 11)           # tileRes >> 0 .. >> 4
ITEM = [1, 8, 8, 16, 24, 24, 0, 0, 0, 0]    # bytes per entry of the CR2W tables (cr2w.py)
OPS = ("raise", "lower", "smooth", "flatten", "set", "ramp", "noise", "terrace")
SHAPES = ("circle", "square")
FALLOFFS = ("smooth", "linear", "hard")


def _props(f, data, start=1):
    out = {}
    for name, tp, off, sz in f.props(data, start):
        if tp == "Float":
            out[name] = struct.unpack_from("<f", data, off)[0]
        elif tp in ("Uint32", "Int32"):
            out[name] = struct.unpack_from("<I" if tp == "Uint32" else "<i", data, off)[0]
        elif tp == "Vector":
            out[name] = {n: struct.unpack_from("<f", data, o)[0] for n, _t, o, _s in f.props(data, off + 1)}
    return out


def falloff(r, radius, kind="smooth"):
    """The brush's weight at distance r: 1 at the centre, 0 from the edge on (smooth: soft at both ends)."""
    if r >= radius:
        return 0.0
    if kind == "hard":
        return 1.0
    if kind == "linear":
        return 1.0 - r / radius
    return 0.5 * (1 + math.cos(math.pi * r / radius))


def _lattice(ix, iy, seed):
    """A fixed random value -1..1 for a lattice point (the same on every build)."""
    h = (ix * 374761393 + iy * 668265263 + seed * 2147483647) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 32767.5 - 1.0


def value_noise(x, y, scale, seed=0):
    """Smooth noise -1..1 with bumps of `scale` metres (value noise, two octaves)."""
    out, amp, total = 0.0, 1.0, 0.0
    for octave in range(2):
        fx, fy = x / scale, y / scale
        ix, iy = math.floor(fx), math.floor(fy)
        tx, ty = fx - ix, fy - iy
        tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
        s = seed + octave * 101
        a = _lattice(ix, iy, s) + (_lattice(ix + 1, iy, s) - _lattice(ix, iy, s)) * tx
        b = _lattice(ix, iy + 1, s) + (_lattice(ix + 1, iy + 1, s) - _lattice(ix, iy + 1, s)) * tx
        out += (a + (b - a) * ty) * amp
        total += amp
        amp, scale = amp * 0.5, scale * 0.5
    return out / total


class Terrain:
    def __init__(self, world, depot=None):
        self.depot = depot or bundles.Depot()
        paths = project.world_paths()
        self.w2w = paths.get(world, world)
        f = CR2W(self.depot.read(self.w2w))
        cm = next(e for e in f.exports if e[0] == "CClipMap")
        p = _props(f, cm[4])
        self.corner = (p["terrainCorner"]["X"], p["terrainCorner"]["Y"])
        self.size = p["terrainSize"] / p["numTilesPerEdge"]           # metres per tile
        self.tiles_per_edge = p["numTilesPerEdge"]
        self.res = p["tileRes"]
        self.low, self.high = p["lowestElevation"], p["highestElevation"]
        self.spacing = self.size / self.res
        self.dir = os.path.join(os.path.dirname(self.w2w), "terrain_tiles")
        self.grids = {}                     # (row, col) -> list of u16, full resolution
        self.originals = {}                 # (row, col) -> the tile's heights before the first stroke changed it
        self.touched = set()

    # --- places
    def tile_path(self, row, col):
        return os.path.join(self.dir, f"tile_{row}_x_{col}_res{self.res}.w2ter")

    def sample_of(self, x, y):
        """Global sample (column from x, row from y) nearest to a world point."""
        return (int(round((x - self.corner[0]) / self.spacing)), int(round((y - self.corner[1]) / self.spacing)))

    def grid(self, row, col):
        if (row, col) not in self.grids:
            raw = self.depot.read(f"{self.tile_path(row, col)}.{HEIGHT_BUFFERS[0]}.buffer")
            self.grids[(row, col)] = list(struct.unpack(f"<{self.res * self.res}H", raw))
        return self.grids[(row, col)]

    def _get(self, gx, gy):
        g = self.grid(gy // self.res, gx // self.res)
        return g[(gy % self.res) * self.res + gx % self.res]

    def _set(self, gx, gy, v):
        row, col = gy // self.res, gx // self.res
        g = self.grid(row, col)
        if (row, col) not in self.originals:
            self.originals[(row, col)] = list(g)
        g[(gy % self.res) * self.res + gx % self.res] = max(0, min(65535, int(round(v))))
        self.touched.add((row, col))

    def change(self, x, y):
        """Metres the strokes moved the ground at a world point (0 where nothing changed)."""
        gx, gy = self.sample_of(x, y)
        if not self._inside(gx, gy):
            return 0.0
        key = (gy // self.res, gx // self.res)
        if key not in self.originals:
            return 0.0
        i = (gy % self.res) * self.res + gx % self.res
        return (self.grids[key][i] - self.originals[key][i]) * (self.high - self.low) / 65535.0

    def ground(self, origin, d, reach=400.0, step=0.5):
        """Where a ray (origin, unit direction d) first meets the ground -> [x, y, z] or None (sky, out of the world).
        Marched in `step` metres, the last step halved down to a few centimetres."""
        prev_t, t = 0.0, 0.0
        while t < reach:
            p = [origin[k] + d[k] * t for k in range(3)]
            gx, gy = self.sample_of(p[0], p[1])
            if self._inside(gx, gy) and p[2] <= self.to_metres(self._get(gx, gy)):
                lo, hi = prev_t, t
                for _ in range(8):
                    mid = (lo + hi) / 2
                    q = [origin[k] + d[k] * mid for k in range(3)]
                    if q[2] <= self.height(q[0], q[1]):
                        hi = mid
                    else:
                        lo = mid
                q = [origin[k] + d[k] * hi for k in range(3)]
                return [q[0], q[1], self.height(q[0], q[1])]
            prev_t, t = t, t + step
        return None

    def _inside(self, gx, gy):
        n = self.tiles_per_edge * self.res
        return 0 <= gx < n and 0 <= gy < n

    # --- heights
    def to_metres(self, v):
        return self.low + v / 65535.0 * (self.high - self.low)

    def to_value(self, metres):
        return (metres - self.low) / (self.high - self.low) * 65535.0

    def height(self, x, y):
        return self.to_metres(self._get(*self.sample_of(x, y)))

    # --- brush
    def _weights(self, s):
        """{sample: brush weight} of a stroke - its circle / square, or the band of a ramp."""
        radius, kind = float(s["radius"]), s.get("falloff", "smooth")
        shape = s.get("shape", "circle")
        if kind not in FALLOFFS or shape not in SHAPES:
            raise ValueError(f"terrain stroke: falloff one of {', '.join(FALLOFFS)}, shape one of {', '.join(SHAPES)}")
        x1, y1 = float(s["x"]), float(s["y"])
        x2, y2 = (float(s["x2"]), float(s["y2"])) if s["op"] == "ramp" else (x1, y1)
        lo = self.sample_of(min(x1, x2) - radius, min(y1, y2) - radius)
        hi = self.sample_of(max(x1, x2) + radius, max(y1, y2) + radius)
        dx, dy = x2 - x1, y2 - y1
        length2 = dx * dx + dy * dy
        out = {}
        for gy in range(lo[1], hi[1] + 1):
            for gx in range(lo[0], hi[0] + 1):
                if not self._inside(gx, gy):
                    continue
                px, py = self.corner[0] + gx * self.spacing, self.corner[1] + gy * self.spacing
                if s["op"] == "ramp":
                    t = ((px - x1) * dx + (py - y1) * dy) / length2 if length2 else 0.0
                    if not 0.0 <= t <= 1.0:
                        continue
                    r = math.hypot(px - (x1 + dx * t), py - (y1 + dy * t))
                elif shape == "square":
                    r, t = max(abs(px - x1), abs(py - y1)), 0.0
                else:
                    r, t = math.hypot(px - x1, py - y1), 0.0
                w = falloff(r, radius, kind)
                if w:
                    out[(gx, gy)] = (w, t)
        return out

    def apply(self, strokes):
        for s in strokes:
            op = s.get("op")
            if op not in OPS:
                raise ValueError(f"terrain stroke: op '{op}' - one of {', '.join(OPS)}")
            strength = float(s.get("strength", 1.0))
            cx, cy = self.sample_of(float(s["x"]), float(s["y"]))
            found = self._weights(s)
            weight = {k: w for k, (w, _t) in found.items()}
            if op in ("raise", "lower"):
                d = self.to_value(strength) - self.to_value(0.0)
                d = d if op == "raise" else -d
                for (gx, gy), w in weight.items():
                    self._set(gx, gy, self._get(gx, gy) + d * w)
            elif op in ("flatten", "set"):
                target = self.to_value(float(s["height"])) if s.get("height") is not None else self._get(cx, cy)
                for (gx, gy), w in weight.items():
                    v = self._get(gx, gy)
                    self._set(gx, gy, v + (target - v) * w * (strength if op == "flatten" else 1.0))
            elif op == "ramp":
                end = self.sample_of(float(s["x2"]), float(s["y2"]))
                h1 = self.to_value(float(s["height"])) if s.get("height") is not None else self._get(cx, cy)
                h2 = self.to_value(float(s["height2"])) if s.get("height2") is not None else self._get(*end)
                for (gx, gy), (w, t) in found.items():
                    v = self._get(gx, gy)
                    self._set(gx, gy, v + (h1 + (h2 - h1) * t - v) * w * strength)
            elif op == "noise":
                scale, seed = float(s.get("scale", 4.0)), int(s.get("seed", 0))
                d = self.to_value(strength) - self.to_value(0.0)
                for (gx, gy), w in weight.items():
                    n = value_noise(gx * self.spacing, gy * self.spacing, scale, seed)
                    self._set(gx, gy, self._get(gx, gy) + d * n * w)
            elif op == "terrace":
                step = float(s.get("step", 1.0))
                for (gx, gy), w in weight.items():
                    v = self._get(gx, gy)
                    m = self.to_metres(v)
                    target = self.to_value(math.floor(m / step + 0.5) * step)
                    self._set(gx, gy, v + (target - v) * w * strength)
            else:                           # smooth: towards the mean of the 3x3 around, read before any change
                old = {}
                for gx, gy in weight:
                    around = [self._get(ax, ay) for ay in (gy - 1, gy, gy + 1) for ax in (gx - 1, gx, gx + 1)
                              if self._inside(ax, ay)]
                    old[(gx, gy)] = (self._get(gx, gy), sum(around) / len(around))
                for (gx, gy), (v, mean) in old.items():
                    self._set(gx, gy, v + (mean - v) * weight[(gx, gy)] * strength)
        return sorted(self.touched)

    # --- writing
    def write(self, out_dir):
        """The touched tiles as cooked files under out_dir (their depot paths) -> the paths written."""
        written = []
        for row, col in sorted(self.touched):
            name = self.tile_path(row, col)
            raw = bytearray(self.depot.read(name))
            full = self.grids[(row, col)]
            levels = {}
            for k, idx in enumerate(HEIGHT_BUFFERS):
                res, step = self.res >> k, 1 << k
                levels[idx] = struct.pack(f"<{res * res}H", *(full[(r * step) * self.res + c * step]
                                                              for r in range(res) for c in range(res)))
            _set_tile_range(raw, min(full), max(full))
            b_off, b_cnt, _ = struct.unpack_from("<III", raw, 0x28 + 5 * 12)
            for i in range(b_cnt):
                idx = struct.unpack_from("<I", raw, b_off + i * 24 + 4)[0]
                if idx in levels:
                    struct.pack_into("<I", raw, b_off + i * 24 + 20, zlib.crc32(levels[idx]))
            _fix_crcs(raw)
            path = os.path.join(out_dir, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(raw)
            for i in range(b_cnt):
                idx = struct.unpack_from("<I", raw, b_off + i * 24 + 4)[0]
                with open(f"{path}.{idx}.buffer", "wb") as f:
                    f.write(levels.get(idx) or self.depot.read(f"{name}.{idx}.buffer"))
            written.append(path)
        return written


    # --- collision
    def collision(self, game):
        """The collision.cache entries of the tiles whose collision changes - the touched ones and the neighbours
        below / to the left, whose pieces end on a touched tile's first row / column - remade from the heights.

        A tile's entry (measured 04.10., tile 33/26 of Novigrad): 64 PhysX heightfields ("NXS\\1" "HFHF"), piece k
        the block k // 8 (rows, from y), k % 8 (columns) of 64 x 64 cells, 65 x 65 samples - the last row / column
        the next block's first, past the tile's edge the neighbour's. A sample: i16 height (tile value - 32767), two
        material bytes (tess flag, 0x7f7f a hole) kept. The piece's lowest / highest sample as floats in its header:
        bounds at +50 / +62, again at +94 / +98; the samples from +102."""
        from . import collision_cache
        import glob
        tiles = set()
        for row, col in self.touched:
            tiles |= {(row, col), (row - 1, col), (row, col - 1), (row - 1, col - 1)}
        tiles = {(r, c) for r, c in tiles if 0 <= r < self.tiles_per_edge and 0 <= c < self.tiles_per_edge}
        names = {self.tile_path(r, c).lower(): (r, c) for r, c in tiles}
        caches = sorted(glob.glob(os.path.join(game, "content", "content*", "collision.cache"))) + \
            sorted(glob.glob(os.path.join(game, "dlc", "*", "content", "collision.cache")))
        found = {}
        for cache in caches:
            found.update(collision_cache.find(cache, names))
        out = []
        last = self.tiles_per_edge * self.res - 1
        for name, (row, col) in sorted(names.items()):
            entry = found.get(name)
            if entry is None:
                continue                    # (a tile without collision: none to change)
            data = bytearray(entry.data())
            starts, i = [], 0
            while (i := data.find(b"NXS\x01HFHF", i)) >= 0:
                starts.append(i)
                i += 8
            if len(starts) != 64:
                raise ValueError(f"{name}: {len(starts)} heightfields in its collision, 64 expected")
            for k, s in enumerate(starts):
                br, bc = divmod(k, 8)
                gy0, gx0 = row * self.res + br * 64, col * self.res + bc * 64
                lo = hi = None
                for r in range(65):
                    for c in range(65):
                        v = min(32767, self._get(min(gx0 + c, last), min(gy0 + r, last)) - 32767)
                        struct.pack_into("<h", data, s + 102 + (r * 65 + c) * 4, v)
                        lo = v if lo is None or v < lo else lo
                        hi = v if hi is None or v > hi else hi
                for off, value in ((50, lo), (62, hi), (94, lo), (98, hi)):
                    struct.pack_into("<f", data, s + off, float(value))
            entry.replace(bytes(data))
            out.append(entry)
        return out


FILE = "terrain.yml"


def load(project_dir):
    """A project's painted terrain: [{"world", "strokes": [...]}, ...], one entry per drag of the brush, in the
    order painted (terrain.yml; none: [])."""
    import yaml
    path = os.path.join(project_dir, FILE)
    if not os.path.exists(path):
        return []
    data = yaml.safe_load(open(path, encoding="utf-8")) or {}
    return [g for g in data.get("groups") or [] if g.get("world") and g.get("strokes")]


def save(project_dir, groups):
    import yaml
    path = os.path.join(project_dir, FILE)
    if not groups:
        if os.path.exists(path):
            os.remove(path)
        return
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# terrain painted in the editor, in the order painted: one entry per drag of the brush\n")
        yaml.safe_dump({"groups": groups}, f, sort_keys=False, default_flow_style=None, width=120)
    os.replace(tmp, path)


def strokes_of(groups, world):
    return [s for g in groups if g["world"] == world for s in g["strokes"]]


def build_into(project_dir, files_dir, cache_dir, log=print):
    """A project's painted terrain into a build: the changed tiles under their game paths in files_dir (the mod
    bundle's files), their collision as cache_dir\\collision.cache. -> the number of tiles (0: nothing painted)."""
    from . import collision_cache, config
    groups = load(project_dir)
    if not groups:
        return 0
    depot = bundles.Depot()
    entries, tiles = [], 0
    for world in dict.fromkeys(g["world"] for g in groups):
        t = Terrain(world, depot)
        touched = t.apply(strokes_of(groups, world))
        t.write(files_dir)
        entries += t.collision(config.load()["game"])
        tiles += len(touched)
        log(f"[build] terrain of {world}: {len(touched)} tiles changed")
    if entries:
        os.makedirs(cache_dir, exist_ok=True)
        with open(os.path.join(cache_dir, "collision.cache"), "wb") as f:
            f.write(collision_cache.write(entries))
    return tiles


def build_mod(world, strokes, mod_dir, work, log=print):
    """Brush strokes on a world's terrain -> a mod (mod_dir: <game>\\Mods\\mod...) with the changed tiles and their
    collision. The game reads both when the world loads."""
    import shutil
    from . import build, collision_cache, config, features
    features.require("Terrain editing")
    cfg = config.load()
    t = Terrain(world)
    tiles = t.apply(strokes)
    log(f"[terrain] {len(strokes)} strokes -> tiles {tiles}")
    if os.path.exists(work):
        shutil.rmtree(work)
    src, content = os.path.join(work, "cooked"), os.path.join(work, "mod", "content")
    t.write(src)
    os.makedirs(content)
    entries = t.collision(cfg["game"])
    with open(os.path.join(content, "collision.cache"), "wb") as f:
        f.write(collision_cache.write(entries))
    log(f"[terrain] collision of {len(entries)} tiles")
    build.pack_and_index(src, content, cfg["wcc"], os.path.dirname(cfg["wcc"]), log)
    if os.path.exists(mod_dir):
        shutil.rmtree(mod_dir)
    shutil.copytree(os.path.join(work, "mod"), mod_dir)
    return tiles


def _set_tile_range(raw, lo, hi):
    """The tile's minHeightValue / maxHeightValue (the export's u16 props) and the export's crc."""
    f = CR2W(bytes(raw))
    e_off = struct.unpack_from("<III", raw, 0x28 + 4 * 12)[0]
    _cls, _fl, _par, size, data_off, _t, _crc = struct.unpack_from("<HHIIIII", raw, e_off)
    for name, _tp, off, _sz in f.props(f.exports[0][4]):
        if name == "maxHeightValue":
            struct.pack_into("<H", raw, data_off + off, hi)
        elif name == "minHeightValue":
            struct.pack_into("<H", raw, data_off + off, lo)
    struct.pack_into("<I", raw, e_off + 20, zlib.crc32(raw[data_off:data_off + size]))


def _fix_crcs(raw):
    """Each table's crc (crc32 of its bytes), then the header's (crc32 of 0xA0 bytes, its own field 0xDEADBEEF)."""
    for i in range(10):
        off, cnt, _crc = struct.unpack_from("<III", raw, 0x28 + i * 12)
        if cnt and ITEM[i]:
            struct.pack_into("<I", raw, 0x28 + i * 12 + 8, zlib.crc32(raw[off:off + cnt * ITEM[i]]))
    struct.pack_into("<I", raw, 0x20, 0xDEADBEEF)
    struct.pack_into("<I", raw, 0x20, zlib.crc32(bytes(raw[:0xA0])))

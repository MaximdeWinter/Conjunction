"""3D preview of the game's meshes: read a cooked .w2mesh (positions, texture coordinates, triangles, the diffuse
texture of each material) and show it turnable in the inspector.

Cooked mesh (checked 30.09. on box_wood and old_chest_container, remaster 5.0): the CMesh's cookedData has
quantizationScale / quantizationOffset, vertexBufferSize, indexBufferOffset and renderChunks - a byte array: a count
(u8), then per chunk 37 bytes:

    vertex type u8, stream offsets 5 x u32 (positions, uvs, normals, ...), streams u8, index offset u32 (bytes, after
    indexBufferOffset), 0x1d, vertex count u16, index count u32, material u8, u8, u8, lod mask u8

The buffer (<mesh>.1.buffer in the bundles) holds the streams: positions u16 x 4 (value / 65535 * scale + offset;
skinned meshes - vertex type 3 - have 16 bytes a vertex there: the bones' indices and weights follow),
uvs half x 2, ...; indices u16, per chunk from 0. Chunks without a uv stream are shadow meshes (not drawn).
A material (exports CMaterialInstance, or an imported .w2mi) has its parameters after its properties: a count, then
size u32, name u16, type u16, value; a texture parameter's value is a handle to an imported .xbm.

Normals: the stream after the uvs, 8 bytes a vertex - the normal as 10:10:10:2 (unsigned), then the tangent. Triangles
wind clockwise; v runs from the bottom of the texture; things face +y.
Colours: a person's templates keep coloringEntries (appearance, componentName, colorShift1 / colorShift2 - hue 0..360,
saturation and luminance -100..100); a tint-mask material shifts its diffuse where its TintMask is set - the diffuse's
red parts by shift 1, its blue parts by shift 2 (striped trousers: red and blue stripes, two colours).
"""
import math
import struct

from PySide6 import QtGui, QtOpenGL, QtOpenGLWidgets

GL_TRIANGLES, GL_FLOAT, GL_DEPTH_TEST, GL_CW = 0x0004, 0x1406, 0x0B71, 0x0900
GL_COLOR_BUFFER_BIT, GL_DEPTH_BUFFER_BIT, GL_TEXTURE_2D, GL_CULL_FACE = 0x4000, 0x0100, 0x0DE1, 0x0B44


# --- reading
class Part:
    """One drawn piece: triangles (a flat list of vertex rows x, y, z, u, v, nx, ny, nz), its texture name and
    whether its texture's alpha cuts it out (hair, leaves, cloth edges)."""

    def __init__(self, rows, texture, cutout=False):
        self.rows, self.texture, self.cutout = rows, texture, cutout
        self.mask = None                                # a tint mask texture ("" = shift all of it)
        self.shift = None                               # ((hue, sat, lum), (hue, sat, lum)) from the template


# materials whose texture alpha is a cut-out mask (their graph's name says so)
CUTOUT = ("hair", "foliage", "leaf", "leaves", "grass", "fur", "cutout", "tree", "branch", "feather")


def _props(f, chunk, start=1):
    return {name: (tp, off, sz) for name, tp, off, sz in f.props(chunk, start)}


def _params(f, chunk):
    """Parameters of a material instance: {name: (type, value bytes)}."""
    props = f.props(chunk)
    end = props[-1][2] + props[-1][3] if props else 1
    data = bytes(chunk[end:])
    out = {}
    i = 2                                               # the end of the properties (name 0)
    if len(data) < i + 4:
        return out
    count = struct.unpack_from("<I", data, i)[0]
    i += 4
    for _ in range(min(count, 200)):
        if i + 8 > len(data):
            break
        size, nm, tp = struct.unpack_from("<IHH", data, i)
        if size < 8:
            break
        out[f.names[nm]] = (f.names[tp], data[i + 8:i + size])
        i += size
    return out


def _graph(f, depot, handle, depth=0):
    """The material graph (.w2mg) a material handle ends in - its name tells how it is drawn."""
    if handle == 0 or depth > 4:
        return ""
    if handle < 0:
        path = f.imports[-handle - 1][0]
        if path.endswith(".w2mg") or not path.endswith(".w2mi") or not depot.exists(path):
            return path
        from .assets import _cr2w_parts
        g = _cr2w_parts(depot.read(path))[0]
        for k, (cls, *_rest) in enumerate(g.exports):
            if cls == "CMaterialInstance":
                return _graph(g, depot, k + 1, depth + 1)
        return path
    cls, _fl, _parent, _tmpl, chunk = f.exports[handle - 1]
    props = _props(f, chunk)
    if "baseMaterial" in props:
        _tp, off, _sz = props["baseMaterial"]
        return _graph(f, depot, struct.unpack_from("<i", chunk, off)[0], depth + 1)
    return ""


DIFFUSE = ("Diffuse", "diffuse", "DiffuseMap", "Diffuse1", "BaseColor", "DiffuseArray")


def _not_colour(param, path):
    """A texture that is no colour: a normal / specular / mask / ambient map (by its parameter or file name)."""
    import re
    if re.search(r"normal|spec|rough|mask|ambient|ao\b|height|detail|translucen|noise", param, re.I):
        return True
    return bool(re.search(r"_(n|s|a|r|m|nm|ao|h)\d*\.xbm$", path, re.I))


def _diffuse(f, depot, handle, depth=0, keys=DIFFUSE):
    """The diffuse texture (.xbm depot path) of a material handle, following imported .w2mi files (or, with other
    `keys`, that texture: only those)."""
    if handle == 0 or depth > 4:
        return None
    if handle > 0:                                      # an export of this file
        cls, _fl, _parent, _tmpl, chunk = f.exports[handle - 1]
        params = _params(f, chunk)
        for key in keys:
            if key in params and params[key][0].startswith("handle:"):
                h = struct.unpack_from("<i", params[key][1])[0]
                if h < 0 and f.imports[-h - 1][0].endswith(".xbm"):
                    return f.imports[-h - 1][0]
                if h < 0 and f.imports[-h - 1][0].endswith(".texarray"):
                    # walls and houses blend layers of an array by vertex colour; the cache keeps each layer as
                    # <array>.texture_<n>.xbm - the first is the base
                    return f.imports[-h - 1][0] + ".texture_0.xbm"
        props = _props(f, chunk)
        if "baseMaterial" in props:                     # the base's diffuse first (the instance may only change
            _tp, off, _sz = props["baseMaterial"]       # its normal map)
            found = _diffuse(f, depot, struct.unpack_from("<i", chunk, off)[0], depth + 1, keys)
            if found:
                return found
        for name, (tp, v) in (params.items() if keys is DIFFUSE else ()):     # any colour texture
            if tp.startswith("handle:") and len(v) >= 4:
                h = struct.unpack_from("<i", v)[0]
                if h < 0:
                    p = f.imports[-h - 1][0]
                    if p.endswith(".xbm") and not _not_colour(name, p):
                        return p
        return None
    path = f.imports[-handle - 1][0]                    # an imported material instance
    if not path.endswith(".w2mi") or not depot.exists(path):
        return None
    from .assets import _cr2w_parts
    g = _cr2w_parts(depot.read(path))[0]
    for k, (cls, *_rest) in enumerate(g.exports):
        if cls == "CMaterialInstance":
            return _diffuse(g, depot, k + 1, depth + 1, keys)
    return None


def _transform(v):
    """EngineTransform: flags u8 (1 position, 2 rotation, 4 scale), then 3 floats for each."""
    pos, rot, scale = [0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [1.0, 1.0, 1.0]
    if not v:
        return pos, rot, scale
    flags, i = v[0], 1
    for bit, target in ((1, pos), (2, rot), (4, scale)):
        if flags & bit and i + 12 <= len(v):
            target[:] = struct.unpack_from("<3f", v, i)
            i += 12
    return pos, rot, scale


def template_meshes(path, depot=None, names=False, depth=0):
    """[(mesh path, (position, rotation, scale))] of a template's mesh components (all its parts; none:
    those of the templates it includes); `names`: [(mesh, transform, component name)]."""
    from .assets import _cr2w_parts
    from .bundles import Depot
    depot = depot or Depot()
    parts = _cr2w_parts(depot.read(path))
    out, seen = [], set()
    for f in parts:                                     # the entity, then its streamed pieces (walls: most of it)
        for cls, _fl, _parent, _tmpl, chunk in f.exports:
            if "MeshComponent" not in cls or "Destruction" in cls:
                continue
            mesh, tr, name = None, None, None
            try:
                props = f.props(chunk)
            except (IndexError, struct.error):          # some parts start right with the first property
                try:
                    props = f.props(chunk, 0)
                except (IndexError, struct.error):
                    continue
            for pname, _tp, off, sz in props:
                v = bytes(chunk[off:off + sz])
                if pname == "mesh":
                    if len(v) >= 4:
                        h = struct.unpack_from("<i", v)[0]
                        mesh = f.imports[-h - 1][0] if h < 0 else None
                    elif len(v) == 2:
                        h = struct.unpack_from("<H", v)[0]
                        mesh = f.imports[h - 1][0] if 0 < h <= len(f.imports) else None
                elif pname == "transform":
                    tr = v
                elif pname == "name":
                    name = v
            if mesh and mesh.endswith(".w2mesh") and (name, mesh) not in seen:
                seen.add((name, mesh))
                # a String: a length byte (0x80: plain ascii, 0x40: one more length byte), then the letters
                label = name[2 if name[0] & 0x40 else 1:].decode("latin-1") if name else ""
                out.append((mesh, _transform(tr), label) if names else (mesh, _transform(tr)))
    if out:
        return out
    tmpl =next((e for e in parts[0].exports if e[0] == "CEntityTemplate"), None) if parts else None
    if tmpl is None or depth > 3:
        return []
    f, chunk = parts[0], tmpl[4]
    props = _props(f, chunk)
    out = []
    if "includes" in props:                             # e.g. a container definition: its mesh entity
        _tp, off, _sz = props["includes"]
        for k in range(struct.unpack_from("<I", chunk, off)[0]):
            h = struct.unpack_from("<i", chunk, off + 4 + 4 * k)[0]
            if h < 0 and depot.exists(f.imports[-h - 1][0]):
                out += template_meshes(f.imports[-h - 1][0], depot, names, depth + 1)
    return out


def _struct_array(f, v):
    """An array of structs as property dicts {name: (type, value bytes)} (each element: 0, properties, 0 0)."""
    n = struct.unpack_from("<I", v)[0]
    out, i = [], 4
    for _ in range(n):
        el = {}
        i += 1
        while i + 2 <= len(v):
            nm = struct.unpack_from("<H", v, i)[0]
            if nm == 0:
                i += 2
                break
            tp, size = struct.unpack_from("<HI", v, i + 2)
            el[f.names[nm]] = (f.names[tp], v[i + 8:i + 4 + size])
            i += 4 + size
        out.append(el)
    return out


def appearance_meshes(path, depot=None, appearance=None):
    """[(mesh, transform)] of a template's appearance (the first, or the named one): the meshes of the templates it
    includes (a person's body, clothes, head)."""
    return [(m, t) for m, t, _c in person(path, depot, appearance)[1]]


def _shift(g, v):
    """A CColorShift struct's (hue, saturation, luminance); what it leaves out is 0."""
    out = {"hue": 0, "saturation": 0, "luminance": 0}
    i = 1
    while i + 8 <= len(v):
        nm = struct.unpack_from("<H", v, i)[0]
        if nm == 0:
            break
        size = struct.unpack_from("<I", v, i + 4)[0]
        key, val = g.names[nm], v[i + 8:i + 4 + size]
        if key == "hue" and len(val) >= 2:
            out[key] = struct.unpack_from("<H", val)[0]
        elif key in out and len(val) >= 1:
            out[key] = struct.unpack_from("<b", val)[0]
        i += 4 + size
    return out["hue"], out["saturation"], out["luminance"]


def coloring(path, depot, depth=0):
    """{(appearance, component): (shift 1, shift 2)} of a template and the templates it includes."""
    from .assets import _cr2w_parts
    out = {}
    if depth > 3 or not depot.exists(path):
        return out
    f = _cr2w_parts(depot.read(path))[0]
    tmpl = next((e for e in f.exports if e[0] == "CEntityTemplate"), None)
    if tmpl is None:
        return out
    chunk = tmpl[4]
    props = _props(f, chunk)
    if "includes" in props:
        _tp, off, _sz = props["includes"]
        for k in range(struct.unpack_from("<I", chunk, off)[0]):
            h = struct.unpack_from("<i", chunk, off + 4 + 4 * k)[0]
            if h < 0:
                out.update(coloring(f.imports[-h - 1][0], depot, depth + 1))
    if "coloringEntries" in props:
        _tp, off, sz = props["coloringEntries"]
        for el in _struct_array(f, bytes(chunk[off:off + sz])):
            app, comp = el.get("appearance"), el.get("componentName")
            if not app or not comp:
                continue
            key = (f.names[struct.unpack_from("<H", app[1])[0]], f.names[struct.unpack_from("<H", comp[1])[0]])
            none = (0, 0, 0)
            out[key] = (_shift(f, el["colorShift1"][1]) if "colorShift1" in el else none,
                        _shift(f, el["colorShift2"][1]) if "colorShift2" in el else none)
    return out


def looks(path, depot, depth=0):
    """({appearance: [template paths it puts together]}, [used appearances]) of a template - its own and those of the
    templates it includes (its own win). The used ones are what the game spawns (the first: the usual look)."""
    from .assets import _cr2w_parts
    apps, used = {}, []
    if depth > 3 or not depot.exists(path):
        return apps, used
    f = _cr2w_parts(depot.read(path))[0]
    tmpl = next((e for e in f.exports if e[0] == "CEntityTemplate"), None)
    if tmpl is None:
        return apps, used
    chunk = tmpl[4]
    props = _props(f, chunk)
    if "appearances" in props:
        _tp, off, sz = props["appearances"]
        for app in _struct_array(f, bytes(chunk[off:off + sz])):
            nm, inc = app.get("name"), app.get("includedTemplates")
            if not nm or not inc:
                continue
            v = inc[1]
            subs = [f.imports[-h - 1][0] for h in struct.unpack_from(f"<{struct.unpack_from('<I', v)[0]}i", v, 4)
                    if h < 0]
            if subs:
                apps[f.names[struct.unpack_from("<H", nm[1])[0]]] = subs
    if "usedAppearances" in props:
        _tp, off, _sz = props["usedAppearances"]
        n = struct.unpack_from("<I", chunk, off)[0]
        used = [f.names[struct.unpack_from("<H", chunk, off + 4 + 2 * k)[0]] for k in range(n)]
    if "includes" in props:
        _tp, off, _sz = props["includes"]
        for k in range(struct.unpack_from("<I", chunk, off)[0]):
            h = struct.unpack_from("<i", chunk, off + 4 + 4 * k)[0]
            if h < 0:
                more, more_used = looks(f.imports[-h - 1][0], depot, depth + 1)
                for key, subs in more.items():
                    apps.setdefault(key, subs)
                used = used or more_used
    return apps, used


def person(path, depot=None, appearance=None):
    """(appearance name, [(mesh, transform, colour shifts or None)]) of a template's appearance (the named one, else
    the usual one - the first the game uses): the meshes of the templates it includes, in the colours the template
    gives them."""
    from .bundles import Depot
    depot = depot or Depot()
    apps, used = looks(path, depot)
    order = ([appearance] if appearance else []) + [u for u in used if u in apps] + list(apps)
    for label in order:
        out = []
        for sub in apps.get(label, []):
            if depot.exists(sub):
                out += template_meshes(sub, depot, names=True)
        if out:
            colours = coloring(path, depot)
            return label, [(m, t, colours.get((label, c))) for m, t, c in out]
    return "", []


SKIP = ("shadowmesh", "\\wounds\\", "_fill.", "proxy", "collision", "_lod", "\\blockout")    # blockout: helper boxes


def shown(mesh):
    """A mesh the 3D preview draws (not shadows, wounds, helpers)."""
    return not any(k in mesh.lower() for k in SKIP)


def entity(path, depot=None, listed=(), look=None):
    """(how, [(mesh, transform, colour shifts or None)]): what the 3D preview draws for a template - its own mesh
    components (only the catalog's `listed` meshes, when it lists some), else a person's look."""
    from .bundles import Depot
    depot = depot or Depot()
    listed = [m for m in listed if shown(m)][:6]
    own = [(m, t, None) for m, t in template_meshes(path, depot) if (m in listed if listed else shown(m))][:12]
    name, look_meshes = person(path, depot, look)
    if look_meshes:                                     # a look (a person, a creature, a thing with variants)
        have = {m for m, _t, _s in look_meshes}
        return f"look {name}", look_meshes + [x for x in own if x[0] not in have]   # + e.g. the neck seam
    if own:
        return "components", own
    return "listed", [(m, None, None) for m in listed]


def entity_parts(path, depot=None, listed=(), look=None):
    """(how, [Part]) of `entity`."""
    from .bundles import Depot
    depot = depot or Depot()
    how, placed = entity(path, depot, listed, look)
    parts = []
    for m, t, shift in placed:
        try:
            parts += read_mesh(m, depot, t, shift)
        except Exception:                               # noqa: BLE001 - a mesh the reader does not know
            pass
    return how, parts


def _place(rows, transform):
    """The rows moved by a component's transform (scale, rotation, position). The rotation is stored roll, pitch,
    yaw in degrees (a door turned to face the other way: 0, 0, 270; roses in a vase lean a little, spin freely):
    roll around y, then pitch around x, then yaw around z."""
    (px, py, pz), (roll, pitch, yaw), (sx, sy, sz) = transform
    if (px, py, pz, pitch, yaw, roll, sx, sy, sz) == (0, 0, 0, 0, 0, 0, 1, 1, 1):
        return rows
    cy, syw = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    cr, sr = math.cos(math.radians(roll)), math.sin(math.radians(roll))

    def turn(x, y, z):
        x, z = x * cr + z * sr, -x * sr + z * cr            # roll: around y
        y, z = y * cp - z * sp, y * sp + z * cp             # pitch: around x
        x, y = x * cy - y * syw, x * syw + y * cy           # yaw: around z
        return x, y, z
    out = list(rows)
    for i in range(0, len(out), 8):
        x, y, z = turn(out[i] * sx, out[i + 1] * sy, out[i + 2] * sz)
        out[i], out[i + 1], out[i + 2] = x + px, y + py, z + pz
        out[i + 5], out[i + 6], out[i + 7] = turn(out[i + 5], out[i + 6], out[i + 7])
    return out


def read_mesh(path, depot=None, transform=None, shift=None):
    """[Part] of the mesh's most detailed level (moved by `transform`; tinted by the colour `shift` its template
    gives it), or [] if it cannot be read."""
    from .assets import _cr2w_parts
    from .bundles import Depot
    depot = depot or Depot()
    f = _cr2w_parts(depot.read(path))[0]
    mesh = next((e for e in f.exports if e[0] == "CMesh"), None)
    if mesh is None:
        return []
    chunk = mesh[4]
    props = _props(f, chunk)
    materials = []
    if "materials" in props:
        _tp, off, sz = props["materials"]
        n = struct.unpack_from("<I", chunk, off)[0]
        materials = list(struct.unpack_from(f"<{n}i", chunk, off + 4))
    _tp, off, sz = props["cookedData"]
    cooked = chunk[off:off + sz]
    cp = _props(f, cooked)

    def vec(name):
        _t, o, _s = cp[name]
        sub = _props(f, cooked[o:o + _s], 1)
        return [struct.unpack_from("<f", cooked, o + sub[k][1])[0] if k in sub else 0.0 for k in "XYZ"]
    scale, offset = vec("quantizationScale"), vec("quantizationOffset")
    _t, o, s = cp["indexBufferOffset"]
    index_base = struct.unpack_from("<I", cooked, o)[0]
    _t, o, s = cp["renderChunks"]
    rc = bytes(cooked[o + 4:o + s])
    buf = depot.read(path + ".1.buffer")
    textures = {}
    parts = []
    count = rc[0]
    for k in range(count):
        r = 1 + 37 * k
        if r + 37 > len(rc):
            break
        streams = struct.unpack_from("<5I", rc, r + 1)
        idx_off = struct.unpack_from("<I", rc, r + 22)[0]
        nverts = struct.unpack_from("<H", rc, r + 27)[0]
        nidx = struct.unpack_from("<I", rc, r + 29)[0]
        mat, lod = rc[r + 33], rc[r + 36]
        if not lod & 1 or streams[1] == 0 or nverts == 0:
            continue                                    # a lower level of detail, or a shadow mesh
        # skinned meshes (vertex type 3) keep bone indices and weights next to each position: 16 bytes a vertex
        stride = (streams[1] - streams[0]) // nverts if streams[1] > streams[0] else 8
        stride = stride if stride in (8, 12, 16, 20, 24) else 8
        raw = buf[streams[0]:streams[0] + stride * nverts]
        pos = [(x / 65535.0 * scale[0] + offset[0], y / 65535.0 * scale[1] + offset[1],
                z / 65535.0 * scale[2] + offset[2])
               for x, y, z in (struct.unpack_from("<3H", raw, stride * i) for i in range(nverts))]
        uvs = list(struct.iter_unpack("<2e", buf[streams[1]:streams[1] + 4 * nverts]))
        # the mesh's own normals: 10:10:10:2 (unsigned, -1..1), then the tangent - smooth where the model is smooth
        normals = None
        if streams[2] and streams[2] + 8 * nverts <= len(buf):
            normals = [(((n & 1023) / 511.5) - 1.0, (((n >> 10) & 1023) / 511.5) - 1.0,
                        (((n >> 20) & 1023) / 511.5) - 1.0)
                       for n, _t in struct.iter_unpack("<II", buf[streams[2]:streams[2] + 8 * nverts])]
        start = index_base + idx_off
        idx = struct.unpack_from(f"<{nidx}H", buf, start)
        rows = []
        for t in range(0, nidx - 2, 3):
            a, b, c = idx[t], idx[t + 1], idx[t + 2]
            if max(a, b, c) >= nverts:
                continue
            pa, pb, pc = pos[a], pos[b], pos[c]
            ux, uy, uz = pb[0] - pa[0], pb[1] - pa[1], pb[2] - pa[2]
            vx, vy, vz = pc[0] - pa[0], pc[1] - pa[1], pc[2] - pa[2]
            nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            ln = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            nx, ny, nz = -nx / ln, -ny / ln, -nz / ln          # the game winds its triangles clockwise
            for v in (a, b, c):
                p, uv = pos[v], uvs[v]
                n = normals[v] if normals else (nx, ny, nz)
                rows += [p[0], p[1], p[2], uv[0], uv[1], n[0], n[1], n[2]]
        if mat not in textures:
            if mat < len(materials):
                graph = _graph(f, depot, materials[mat]).lower()
                mask = _diffuse(f, depot, materials[mat], keys=("TintMask",)) if shift else None
                if shift and mask is None and "colorshift" in graph:
                    mask = ""                           # the whole material takes the first shift
                textures[mat] = (_diffuse(f, depot, materials[mat]), any(w in graph for w in CUTOUT), mask)
            else:
                textures[mat] = (None, False, None)
        tex, cutout, mask = textures[mat]
        part = Part(_place(rows, transform) if transform else rows, tex, cutout)
        if mask is not None:
            part.mask, part.shift = mask, shift
        parts.append(part)
    return parts


# --- showing
VERTEX = """
attribute vec3 pos;
attribute vec2 uv;
attribute vec3 normal;
uniform mat4 mvp;
uniform mat4 model;
varying vec2 v_uv;
varying vec3 v_normal;
void main() {
    gl_Position = mvp * vec4(pos, 1.0);
    v_uv = uv;
    v_normal = normalize((model * vec4(normal, 0.0)).xyz);
}
"""
FRAGMENT = """
uniform sampler2D tex;
uniform sampler2D mask;
uniform float textured;
uniform float cutout;
uniform float tinted;                                   // 0 no, 1 by the mask, 2 all of it by shift 1
uniform vec3 shift1;                                    // hue 0..1, saturation and luminance -1..1
uniform vec3 shift2;
varying vec2 v_uv;
varying vec3 v_normal;
vec3 hsl(vec3 c) {
    float hi = max(max(c.r, c.g), c.b), lo = min(min(c.r, c.g), c.b), l = (hi + lo) * 0.5, d = hi - lo;
    if (d < 1e-5) return vec3(0.0, 0.0, l);
    float s = l > 0.5 ? d / (2.0 - hi - lo) : d / (hi + lo);
    float h = hi == c.r ? (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0) : hi == c.g ? (c.b - c.r) / d + 2.0
                                                                                  : (c.r - c.g) / d + 4.0;
    return vec3(h / 6.0, s, l);
}
vec3 rgb(vec3 c) {
    vec3 k = clamp(abs(mod(c.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return c.z + c.y * (k - 0.5) * (1.0 - abs(2.0 * c.z - 1.0));
}
vec3 shifted(vec3 c, vec3 sh) {
    vec3 h = hsl(c);
    h.x = fract(h.x - sh.x);                        // the game turns the hue the other way
    h.y = clamp(h.y * (1.0 + sh.y), 0.0, 1.0);
    h.z = sh.z > 0.0 ? mix(h.z, 1.0, sh.z) : h.z * (1.0 + sh.z);
    return rgb(h);
}
void main() {
    vec4 t = textured > 0.5 ? texture2D(tex, v_uv) : vec4(0.62, 0.62, 0.64, 1.0);
    if (cutout > 0.5 && t.a < 0.45) discard;            // hair, leaves: the texture's alpha cuts them out
    if (tinted > 1.5) {
        t.rgb = shifted(t.rgb, shift1);
    } else if (tinted > 0.5) {                          // the template's colours where the tint mask says
        // the mask says where colour goes; the diffuse says which: red parts take shift 1, blue parts shift 2
        vec4 m = texture2D(mask, v_uv);
        vec3 c = t.rgb;
        float second = clamp((c.b - c.r) * 4.0 + 0.5, 0.0, 1.0);
        vec3 tinted_c = mix(shifted(c, shift1), shifted(c, shift2), second);
        t.rgb = mix(c, tinted_c, max(m.r, m.g));
    }
    vec3 base = pow(t.rgb, vec3(2.2));                  // the texture is sRGB: light in linear space
    vec3 n = normalize(v_normal);
    if (!gl_FrontFacing) n = -n;                        // both sides (cloth, leaves, open shapes)
    vec3 sun = normalize(vec3(0.45, -0.75, 0.55));
    float diff = max(dot(n, sun), 0.0);
    float sky = 0.5 + 0.5 * n.z;                        // light from above, darker from below
    vec3 ambient = mix(vec3(0.10, 0.09, 0.08), vec3(0.34, 0.37, 0.42), sky);
    vec3 to_eye = vec3(0.0, -1.0, 0.0);                 // the camera looks along +y
    vec3 half_v = normalize(sun + to_eye);
    float shine = pow(max(dot(n, half_v), 0.0), 32.0) * 0.12 * diff;
    vec3 color = base * (ambient + diff * vec3(1.05, 0.98, 0.9)) + vec3(shine);
    gl_FragColor = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
}
"""


class MeshView(QtOpenGLWidgets.QOpenGLWidget):
    """A turnable mesh: drag to turn, wheel to come closer. `show_parts(parts)` after `read_mesh`."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.parts, self.gl_parts = [], []
        self.yaw, self.pitch, self.dist = 215.0, 20.0, 3.0   # the game faces things along +y: from the front, a little turned
        self.center, self.radius = [0.0, 0.0, 0.0], 1.0
        self.last = None
        self.program = None
        self.pending = False
        self.images = {}                                # texture name -> QImage (read in the worker)
        self.setMinimumSize(200, 200)
        fmt = QtGui.QSurfaceFormat()
        fmt.setSamples(4)                               # smooth edges
        fmt.setDepthBufferSize(24)
        self.setFormat(fmt)

    def show_parts(self, parts, images=None):
        self.parts, self.images = parts, images or {}
        pts = [(p.rows[i], p.rows[i + 1], p.rows[i + 2]) for p in parts for i in range(0, len(p.rows), 8)]
        if pts:
            lo = [min(q[k] for q in pts) for k in range(3)]
            hi = [max(q[k] for q in pts) for k in range(3)]
            self.center = [(lo[k] + hi[k]) / 2 for k in range(3)]
            self.radius = max(0.05, max(hi[k] - lo[k] for k in range(3)) / 2)
            self.dist = self.radius * 3.2
        self.pending = True
        self.update()

    # --- GL
    def initializeGL(self):
        self.program = QtOpenGL.QOpenGLShaderProgram(self)
        self.program.addShaderFromSourceCode(QtOpenGL.QOpenGLShader.Vertex, VERTEX)
        self.program.addShaderFromSourceCode(QtOpenGL.QOpenGLShader.Fragment, FRAGMENT)
        self.program.bindAttributeLocation("pos", 0)
        self.program.bindAttributeLocation("uv", 1)
        self.program.bindAttributeLocation("normal", 2)
        self.program.link()

    def _texture(self, name):
        img = self.images.get(name)
        if img is None or img.isNull():
            return None
        tex = QtOpenGL.QOpenGLTexture(img)              # Qt flips it; the game stores v from the bottom too
        tex.setMinificationFilter(QtOpenGL.QOpenGLTexture.LinearMipMapLinear)
        tex.setMagnificationFilter(QtOpenGL.QOpenGLTexture.Linear)
        tex.setWrapMode(QtOpenGL.QOpenGLTexture.Repeat)
        return tex

    def _upload(self):
        import array
        for vbo, tex, _n, _p, mask in self.gl_parts:
            vbo.destroy()
            for t in (tex, mask):
                if t:
                    t.destroy()
        self.gl_parts = []
        for p in self.parts:
            if not p.rows:
                continue
            vbo = QtOpenGL.QOpenGLBuffer()
            vbo.create()
            vbo.bind()
            data = array.array("f", p.rows).tobytes()
            vbo.allocate(data, len(data))
            vbo.release()
            tex = self._texture(p.texture)
            mask = self._texture(p.mask) if p.mask else None
            self.gl_parts.append((vbo, tex, len(p.rows) // 8, p, mask))
        self.pending = False

    def paintGL(self):
        f = self.context().functions()
        f.glClearColor(0.19, 0.2, 0.22, 1.0)
        f.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
        f.glEnable(GL_DEPTH_TEST)
        f.glFrontFace(GL_CW)                            # the game's triangles face this way
        if self.pending:
            self._upload()
        if not self.gl_parts or self.program is None:
            return
        model = QtGui.QMatrix4x4()
        model.rotate(self.pitch, 1, 0, 0)
        model.rotate(-self.yaw, 0, 0, 1)
        model.translate(-self.center[0], -self.center[1], -self.center[2])
        view = QtGui.QMatrix4x4()
        view.lookAt(QtGui.QVector3D(0, -self.dist, 0), QtGui.QVector3D(0, 0, 0), QtGui.QVector3D(0, 0, 1))
        proj = QtGui.QMatrix4x4()
        proj.perspective(40.0, max(1, self.width()) / max(1, self.height()), self.radius * 0.02, self.radius * 50)
        self.program.bind()
        self.program.setUniformValue("mvp", proj * view * model)
        self.program.setUniformValue("model", model)
        self.program.setUniformValue1i("tex", 0)
        self.program.setUniformValue1i("mask", 1)
        for vbo, tex, n, part, mask in self.gl_parts:
            vbo.bind()
            self.program.setUniformValue1f("cutout", 1.0 if part.cutout and tex else 0.0)
            tinted = 0.0
            if tex and part.shift and (mask or part.mask == ""):
                tinted = 1.0 if mask else 2.0
                for k, (hue, sat, lum) in enumerate(part.shift):
                    self.program.setUniformValue(f"shift{k + 1}", QtGui.QVector3D(hue / 360.0, sat / 100.0,
                                                                                  lum / 100.0))
                if mask:
                    mask.bind(1)
            self.program.setUniformValue1f("tinted", tinted)
            self.program.enableAttributeArray(0)
            self.program.enableAttributeArray(1)
            self.program.enableAttributeArray(2)
            self.program.setAttributeBuffer(0, GL_FLOAT, 0, 3, 32)
            self.program.setAttributeBuffer(1, GL_FLOAT, 12, 2, 32)
            self.program.setAttributeBuffer(2, GL_FLOAT, 20, 3, 32)
            if tex:
                tex.bind(0)
            self.program.setUniformValue1f("textured", 1.0 if tex else 0.0)
            f.glDrawArrays(GL_TRIANGLES, 0, n)
            if mask and tinted:
                mask.release(1)
            if tex:
                tex.release()
            vbo.release()
        self.program.release()

    # --- turning
    def mousePressEvent(self, e):
        self.last = e.position()

    def mouseMoveEvent(self, e):
        if self.last is None:
            return
        d = e.position() - self.last
        self.last = e.position()
        self.yaw -= d.x() * 0.5                         # drag right: it turns right
        self.pitch = max(-89.0, min(89.0, self.pitch + d.y() * 0.5))
        self.update()

    def mouseReleaseEvent(self, e):
        self.last = None

    def wheelEvent(self, e):
        self.dist = max(self.radius * 0.6, min(self.radius * 20, self.dist * (0.9 if e.angleDelta().y() > 0 else 1.1)))
        self.update()


def load_images(parts, max_side=512):
    """QImages of the parts' textures (a smaller level of the texture: enough for a preview)."""
    from .textures import TextureCache
    global _TC
    try:
        _TC
    except NameError:
        _TC = None
    if _TC is None:
        _TC = TextureCache()
    out = {}
    for name in {p.texture for p in parts if p.texture} | {p.mask for p in parts if p.mask}:
        img = _TC.image(name, max_side=max_side)
        if img is not None:
            data = img.convert("RGBA").tobytes()
            q = QtGui.QImage(data, img.width, img.height, QtGui.QImage.Format_RGBA8888).copy()
            out[name] = q
    return out

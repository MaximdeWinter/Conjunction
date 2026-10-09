"""The maker's mark inside a quest (Maxim 06.10.: "mit den absurd minimalsten Abweichungen"). Nothing is added that
one could find and cut out - the mark is in values the quest has anyway:

- **GUIDs**: every GUID of the built quest (blocks, journal entries, layers) is derived from the project's seed, the
  maker's signature of the project's uid (identity.Profile.project_seed). Without the seed they look random; with it
  each one can be worked out again. Changing them breaks every save that is in the quest.
- **Placed objects**: the position carries a digit below the millimetre and the rotation one below the hundredth of
  a degree, worked out from the seed of the profile that placed it (under half a millimetre / 0.005 degrees off -
  nothing anyone can see, and the game keeps it).

Who holds a seed can check any copy - a built mod, a .w3q, a project - without the original; anyone can check that
a seed is that key's (it is a signature). An object moved by someone else carries that person's mark from then on.

    ensure(project)                      a uid and, for a project without one, the maker's mark (meta "mark")
    project_seed(project) -> bytes|None  the seed the GUIDs come from
    stamp(project, pos, rot) -> pos, rot the active profile's digits in a placed object's values
    object_score(objects, seed) -> (matches, digits)
    objects_marked(objects, seed) -> (objects with all six digits the seed's, objects)
    verdict(matches, digits) -> (z, text)
"""
import hashlib
import hmac
import math
import uuid

POS_STEP = 0.001                    # what the project keeps (mm) - the mark sits in the tenth below
ROT_STEP = 0.01                     # degrees


def ensure(project):
    """A uid for the project and the maker's mark, saved; True when something was added."""
    from . import identity
    changed = False
    if not project.meta.get("uid"):
        project.meta["uid"] = uuid.uuid4().hex
        changed = True
    if not project.meta.get("mark"):
        p = identity.active()
        if p is not None:
            project.meta["mark"] = {"key": p.public, "seed": p.project_seed(project.meta["uid"]).hex()}
            changed = True
    if changed:
        project.save_meta()
    return changed


def project_seed(project_or_meta):
    meta = getattr(project_or_meta, "meta", project_or_meta) or {}
    m = meta.get("mark") or {}
    try:
        return bytes.fromhex(m["seed"]) if m.get("seed") else None
    except ValueError:
        return None


def seed_is_theirs(meta):
    """Is the project's mark seed the signature of its uid by the key it names? (anyone can check this)"""
    from . import identity
    m = (meta or {}).get("mark") or {}
    try:
        return identity.verify(m["key"], b"cj-mark/1|" + str(meta["uid"]).encode("utf-8"), bytes.fromhex(m["seed"]))
    except (KeyError, ValueError):
        return False


def _deg(v):
    """An angle as the game keeps it: 0 .. 360 (a layer turns -0.004 into 359.996)."""
    return float(v) % 360.0


def _digits(seed, pos, rot):
    """The grid point each value sits next to (a position: the nearest mm; an angle in 0 .. 360: the hundredth of a
    degree below it) and the digit the seed gives it."""
    cell = [round(v / POS_STEP) for v in pos[:3]] + [math.floor(round(_deg(v) / ROT_STEP, 6)) for v in rot[:3]]
    h = hmac.new(seed, ("obj|" + ",".join(map(str, cell))).encode("ascii"), hashlib.sha256).digest()
    return cell, [b % 10 for b in h[:6]]


def stamp_values(seed, pos, rot):
    cell, d = _digits(seed, pos, rot)
    # a position: the digit as a tenth of a mm around its mm (-0.45 .. +0.45 mm); an angle: above its hundredth of a
    # degree (0.0005 .. 0.0095 degrees), never across 0 / 360
    p = [round((cell[i] + (d[i] - 4.5) / 10) * POS_STEP, 7) for i in range(3)]
    r = [round((cell[3 + i] + (d[3 + i] + 0.5) / 10) * ROT_STEP, 7) for i in range(min(3, len(rot)))]
    return p, r


def stamp(project, pos, rot):
    """pos, rot with the active profile's digits (unchanged without a profile)."""
    from . import identity
    p = identity.active()
    if p is None or len(pos) < 3 or len(rot) < 3:
        return pos, rot
    if not project.meta.get("uid"):
        ensure(project)
    return stamp_values(p.project_seed(project.meta["uid"]), pos, rot)


KEPT = 1024.0                       # m: beyond, the game's float32 cannot hold a tenth of a millimetre (x, y of the
                                    # big worlds) - those digits are written but not looked at


def object_score(objects, seed):
    """(digits that match, digits looked at) over placed objects [{pos, rot}]: every rotation digit, the position
    digits of values the game's float32 keeps (below KEPT)."""
    match = total = 0
    for o in objects:
        pos, rot = o.get("pos") or [], o.get("rot") or []
        if len(pos) < 3 or len(rot) < 3:
            continue
        cell, d = _digits(seed, pos, rot)
        for i, v in enumerate(list(pos[:3]) + list(rot[:3])):
            if i < 3 and abs(v) >= KEPT:
                continue
            if i < 3:
                got = round((v / POS_STEP - cell[i]) * 10 + 4.5)
            else:
                got = math.floor(round((_deg(v) / ROT_STEP - cell[i]) * 10, 4))
            total += 1
            match += got == d[i]
    return match, total


def objects_marked(objects, seed):
    """(objects whose digits are all this seed's, objects looked at): an object placed or moved by someone else, or
    before marks, does not count - chance gives four to six right one time in 10 000 to a million."""
    k = n = 0
    for o in objects:
        m, t = object_score([o], seed)
        if t >= 4:                                      # (at least the height and the three rotations)
            n += 1
            k += m == t
    return k, n


def objects_verdict(k, n):
    if n == 0:
        return "nothing to look at"
    return "yes" if k >= 2 else ("likely" if k == 1 else "no")


def guid_score(files, qid, seed):
    """(GUIDs that are this seed's, GUIDs looked at) in a built quest's files {path below the DLC folder: bytes}."""
    from .stable_ids import expected_guids
    match = total = 0
    for rel, (want, now) in expected_guids(files, qid, seed).items():
        total += 1
        match += want == now
    return match, total


def verdict(match, total, chance=0.1):
    """z over chance, and what it means."""
    if total == 0:
        return 0.0, "nothing to look at"
    z = (match - total * chance) / math.sqrt(total * chance * (1 - chance))
    if match == total and total >= 6 or z >= 6:
        return z, "yes"
    if z >= 3:
        return z, "likely"
    return z, "no"

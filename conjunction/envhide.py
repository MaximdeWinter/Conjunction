"""Areas where the game's own terrain, foliage (trees, bushes, grass) or water is not drawn: the engine's
CTriggerAreaEnvironmentVisibilityComponent, as two of the game's quests use it (q605's final chamber hides
mountains behind it, q704's arena its foliage). A place object with `envhide` becomes an entity of the quest's own
with that component, in the place's layer - there while the place is shown, gone when a step hides the place.

    {"envhide": {"points": [[dx, dy], ...], "height": 20, "foliage": true, "terrain": false, "water": false},
     "pos": [x, y, z], "rot": [0, 0, 0], "id": "clearing"}

`points`: the area's outline around `pos` (metres, on the ground plane); `height`: how far up from `pos` it reaches.

radish does not know the class (it is newer than its list): Conjunction hands radish a repository folder of its own,
radish's with one file more (RTTI) - the user's radish install stays as it is.
"""
import os
import shutil

from . import config

TEMPLATE = "cj_envhide"           # what a hide area object names as its template until the build makes its entity
RTTI_FILE = "rtti-conjunction.repo.yml"
RTTI = """# Conjunction (conjunction): engine classes radish does not list
rtti:
  classes:
    CTriggerAreaEnvironmentVisibilityComponent:
      .extends: CTriggerAreaComponent
      .adds:
        hideTerrain: bool
        hideFoliage: bool
        hideWater: bool
"""


def radish_repo(cfg=None):
    """radish's repository folder plus Conjunction's RTTI file, kept beside Conjunction's config (refreshed when
    radish's own files are newer) -> its path, for w2quest --repo-dir."""
    cfg = cfg or config.load()
    src = os.path.join(cfg["radish"], "repo.quests")
    dst = os.path.join(os.path.dirname(config.PATH), "radish_repo")
    newest = max((os.path.getmtime(os.path.join(src, f)) for f in os.listdir(src)), default=0)
    mine = os.path.join(dst, RTTI_FILE)
    if not os.path.exists(mine) or os.path.getmtime(mine) < newest or open(mine, encoding="utf-8").read() != RTTI:
        if os.path.isdir(dst):
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
        with open(mine, "w", encoding="utf-8", newline="\n") as f:
            f.write(RTTI)
    return dst


def entity_name(place, oid):
    return f"cj_envhide_{place}_{oid}".lower()


def entity(spec):
    """The radish entity definition for an area object's `envhide`."""
    pts = [[float(p[0]), float(p[1]), 0.0, 1.0] for p in spec.get("points") or []]
    if len(pts) < 3:
        raise ValueError("A hide area needs at least three points")
    return {"entityObject": {".type": "CEntity", "components": {"hide": {
        ".type": "CTriggerAreaEnvironmentVisibilityComponent",
        "height": float(spec.get("height", 20.0)),
        "localPoints": pts,
        "hideFoliage": bool(spec.get("foliage", True)),
        "hideTerrain": bool(spec.get("terrain", False)),
        "hideWater": bool(spec.get("water", False))}}}}


def area_object(world_points, height=20.0, foliage=True, terrain=False, water=False, oid=None):
    """A place object from an outline drawn in the world ([x, y, z] points): placed at their centre, on the
    lowest of them, the outline kept relative to it."""
    if len(world_points) < 3:
        raise ValueError("A hide area needs at least three points")
    cx = sum(p[0] for p in world_points) / len(world_points)
    cy = sum(p[1] for p in world_points) / len(world_points)
    z = min(p[2] for p in world_points)
    o = {"envhide": {"points": [[round(p[0] - cx, 3), round(p[1] - cy, 3)] for p in world_points],
                     "height": float(height), "foliage": bool(foliage), "terrain": bool(terrain),
                     "water": bool(water)},
         "pos": [round(cx, 3), round(cy, 3), round(z - 1.0, 3)], "rot": [0.0, 0.0, 0.0],
         "template": TEMPLATE, "actor": False}     # (the build puts the quest's own entity in its place)
    if oid:
        o["id"] = oid
    return o

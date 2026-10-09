"""What a placed NPC does where it stands: the game's work and idle actions (radish's repo.quests/all.actions), sorted
into standing / sitting / kneeling / lying and named in plain words. Quest-only and adult ones are left out."""
import os
import re

import yaml

from . import config

SKIP = re.compile(r"^(q\d|mq|sq|bob|e3|poi|ep\d|dlg)|sex|prostitute|flirt|nude|dancing_sexy")
GROUPS = {"man": ["idle_man", "work_man", "dining_man", "resting_man", "default_man"],
          "woman": ["idle_woman", "work_woman", "dining_woman", "resting_woman", "default_man"]}  # resting: the bath
POSTURE = [("stand", "Standing"), ("sit", "Sitting"), ("kneel", "Kneeling"), ("lie", "Lying")]
_CACHE = {}


def label(job):
    """'stand_md_chopping_wood_jt' -> 'chopping wood'."""
    words = [w for w in job.split("_") if w not in ("jt", "ap", "m", "w", "mw", "md", "mwd", "mwdc", "mwc", "d", "i")]
    if words and words[0] in ("stand", "stands", "sit", "kneel", "lie"):
        words = words[1:]
    text = " ".join(w for w in words if not w.isdigit()) or job
    return text.replace("  ", " ")


def actions(gender="man"):
    """[(posture label, [(action key 'group/job', label)])] for a man or a woman."""
    if gender in _CACHE:
        return _CACHE[gender]
    try:
        path = os.path.join(config.load()["radish"], "repo.quests", "all.actions.repo.yml")
        repo = yaml.safe_load(open(path, encoding="utf-8"))["repository"]["actions"]
    except (OSError, KeyError, yaml.YAMLError):
        repo = {}
    seen, by = set(), {k: [] for k, _l in POSTURE}
    for group in GROUPS[gender]:
        for job in (repo.get(group) or {}):
            if SKIP.search(job) or job in seen:
                continue
            seen.add(job)
            posture = next((k for k, _l in POSTURE if job.startswith(k)), "stand")
            by[posture].append((f"{group}/{job}", label(job)))
    out = [(lab, sorted(by[k], key=lambda t: t[1])) for k, lab in POSTURE if by[k]]
    _CACHE[gender] = out
    return out


def gender_of(template):
    """Woman or man: by the body the catalog found in the template (woman_* / man_* meshes - Keira Metz has no
    'woman' in her path, 01.10.), else by words in the path."""
    try:
        from .assets import Assets
        row = Assets().template(template) if Assets.ready() else None
    except Exception:                               # noqa: BLE001 - no catalog: the path decides
        row = None
    meshes = (row or {}).get("meshes") or ""
    if "woman_" in meshes or "\\\\woman" in meshes:
        return "woman"
    if "man_" in meshes:
        return "man"
    t = template.lower()
    return "woman" if any(w in t for w in ("woman", "female", "girl", "_f_", "wife", "lady")) else "man"

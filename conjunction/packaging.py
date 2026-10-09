"""Quest packages (Maxim, 01.10.): a quest made with Conjunction as one file anyone with Conjunction can play.

    path = export(project_path, include_source=False)      # -> Documents\\Conjunction\\exports\\<id>-<version>\\<id>-<version>.w3q
    m = read_manifest(path)

A .w3q is a zip laid out as the game's folders - Conjunction's library installs it, and a mod manager (Vortex) can
put it straight into the game as well (Conjunction then checks it the same way, library.by_hand):
    dlc/dlc<id>/...                      the built DLC: players build nothing
    dlc/dlc<id>/conjunction_quest.yml        the manifest: what it is and what it needs (below)
    dlc/dlc<id>/conjunction_source/...       the project (quest, places, its own items) - only if its author shares it
    Mods/moddlc<id>/...                  the game's files it changes, if any (a replaced scene)
(Files of suites before 1.0: manifest.yml, dlc/..., mod/..., source/... in the root - still read.)

The manifest: id, title, author, version, description, made (date), suite (fingerprint), runtime (the runtime
scripts' version it needs), game (needs the remaster scripts), expansions it uses (Hearts of Stone / Blood and Wine,
from the templates of its places), packs (below), baked (voice lines of Conjunction's voice packs it carries in its own
DLC), languages, strings ([first, last] of its text ids: two quests whose ranges overlap clash; strings_idspace:
radish's space, read by older suites), source (yes / no).

`packs`: every mod the quest takes something from (content.py - Conjunction knows no list of packs, only what is in the
author's game): {id, name, author, version, url, detect (paths in the game that show it is there), used: [{ref, kind,
name}] - exactly the things taken}. A content pack (a mod with the marker conjunction_pack.yml) brings its own name,
version and link; a mod without one is known by its folder and what the author said about it.
"""
import datetime
import os
import shutil
import zipfile

import yaml

from . import APP_NAME, config
from . import paths

EXPORTS = paths.EXPORTS
RUNTIME_VERSION = 1                     # the runtime scripts (mod/runtime): raised when quests need new functions
EXPANSIONS = {"dlc\\ep1\\": "Hearts of Stone", "dlc\\bob\\": "Blood and Wine"}


def expansions_used(project):
    used = set()
    for place in project.places.values():
        for o in place.get("objects", []):
            t = str(o.get("template", "")).lower()
            used.update(name for prefix, name in EXPANSIONS.items() if t.startswith(prefix))
    return sorted(used)


def baked_packs(project):
    """Content packs whose lines the quest carries itself ({pack id: lines used})."""
    out = {}
    q = project.meta.get("quest") or {}
    stack = [q]
    while stack:
        x = stack.pop()
        if isinstance(x, dict):
            if x.get("voice_pack"):
                pack = str(x["voice_pack"]).split("/")[0]
                out[pack] = out.get(pack, 0) + 1
            stack += list(x.values())
        elif isinstance(x, list):
            stack += x
    return out


def manifest(project, include_source=False, version=None, packs=None):
    """`packs`: the mods it takes things from (content.manifest_packs) - found here when not given."""
    from .bugreport import _suite_fingerprint
    from .quest import idspace
    meta = project.meta
    q = meta.get("quest") or {}
    langs = ["en"]
    packed = os.path.join(project.path, "build", "packed", "content")
    if os.path.isdir(packed):
        langs = sorted(f[:-10] for f in os.listdir(packed) if f.endswith(".w3strings"))
    place = meta.get("kind") == "place"
    return {"id": project.id, "kind": "place" if place else "quest",
            "title": (meta.get("name") if place else q.get("title")) or meta.get("name", project.id),
            "author": meta.get("author", ""), "version": str(version or meta.get("version", "1.0")),
            "description": q.get("description") or meta.get("description", ""),
            "made": datetime.date.today().isoformat(), "suite": _suite_fingerprint()[0],
            "suite_version": _version(),
            "runtime": 0,                   # (0: the quest carries the runtime functions it calls - scriptlib.py)
            "game": "remaster", "expansions": expansions_used(project),
            "packs": packs if packs is not None else _packs(project), "baked": baked_packs(project),
            "languages": langs,
            "strings_idspace": idspace(project.id), "strings": strings_range(project),
            "after": str(q.get("after") or "").lower() or None, "replaces": replaced_files(project),
            "starts": None if place else ((meta.get("page") or {}).get("starts") or starts_with(project)),
            "source": bool(include_source)}


WORLD_NAMES = {"novigrad": "Velen and Novigrad", "velen": "Velen and Novigrad", "skellige": "Skellige",
               "kaer_morhen": "Kaer Morhen", "prologue": "White Orchard", "prologue_winter": "White Orchard",
               "bob": "Toussaint", "toussaint": "Toussaint"}


def starts_with(project):
    """How the quest begins, for players: {text: the first step's line, world: where} (None: unknown)."""
    from . import quest
    q = project.meta.get("quest") or {}
    try:
        if quest.is_graph(q):                       # the step the start wires to (06.10.: the nodes' order put the
            nodes = q.get("nodes") or {}            # end block first - "Starts: end")
            first = [dst for src, _out, dst in q.get("links") or [] if src == "start" and dst in nodes]
            steps = [nodes[first[0]]["step"]] if first else []
        else:
            steps = [st for st in quest.all_steps(q) if quest.step_type(st)[0] != "chapter"]
    except Exception:                               # noqa: BLE001 - a graph the reader does not know: no hint
        steps = []
    if not steps:
        return None
    kind, a = quest.step_type(steps[0])
    text = (a or {}).get("text") or quest.default_text(kind, a or {}, q.get("items"))
    worlds = [p.get("world") for p in project.places.values() if p.get("world")]
    world = worlds[0] if worlds else ""
    return {"text": str(text or kind), "world": WORLD_NAMES.get(str(world).lower(), str(world).title())}


def replaced_files(project):
    """The game's files the quest changes (its mod part: a game scene swapped, a game quest it goes into) - two
    quests changing the same one cannot both work."""
    root = os.path.join(project.path, "build", "overrides")
    out = []
    for r, _d, files in os.walk(root):
        out += [os.path.relpath(os.path.join(r, f), root).replace("/", "\\").lower() for f in files]
    return sorted(out)


def _version():
    from . import __version__
    return __version__


def strings_range(project):
    """[first, last] of the quest's text ids (build.wide_strings: its own block in the wide field)."""
    from .build import wide_strings
    from .quest import idspace
    wide = wide_strings(project, project.id)
    lo = wide if wide is not None else 2110000000 + idspace(project.id) * 1000
    return [lo, lo + 999]


def _packs(project):
    from . import content
    try:
        return content.manifest_packs(project, labels=content.labeler())[0]
    except OSError:                                 # no game here (a test, a moved folder): nothing found
        return []


ID_FILE = ".conjunction_id"             # in an export's folder: whose it is (the quest's id)


def export_folder(m):
    """The export's folder, named as the quest (Maxim 08.10.: 'The Lost Ring', not thelostring110078-1.0): a name
    another quest already has gets a number. A new version goes into the same folder."""
    import re
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", m.get("title") or "").strip().rstrip(".") or m["id"]
    folder, n = os.path.join(EXPORTS, name), 2
    while os.path.isdir(folder) and export_id(folder) not in (None, m["id"]):
        folder, n = os.path.join(EXPORTS, f"{name} ({n})"), n + 1
    return folder


def export_id(folder):
    try:
        return open(os.path.join(folder, ID_FILE), encoding="utf-8").read().strip() or None
    except OSError:
        return None


def find_export(qid):
    """The folder of a quest's export (by its id), or None - also one of the old names (<id>-<version>)."""
    if not os.path.isdir(EXPORTS):
        return None
    found = [os.path.join(EXPORTS, d) for d in os.listdir(EXPORTS) if os.path.isdir(os.path.join(EXPORTS, d)) and
             (export_id(os.path.join(EXPORTS, d)) == qid or d.lower().startswith(f"{qid}-".lower()))]
    return max(found, key=os.path.getmtime) if found else None


def export(project_path, include_source=False, version=None, log=print, packs=None, rebuild=False):
    """The built quest as a .w3q (it must have been built: Build & Play or Check + build). `packs`: as manifest().
    rebuild: built again first (the export window changed the quest's name: the journal shows it)."""
    from .project import Project
    project = Project(project_path)
    log("[export] checking the quest")
    if project.id != project.base_id or rebuild:
        # the last build was a test run (<id>r<n>): players get the quest under its own id - built again without it
        run = project.meta.pop("run", None)
        project.save_meta()
        from . import build as builder
        log(f"[export] Built again as {project.base_id} (the last build was a test run)")
        try:
            builder.build(project_path, install=False, log=log)
        finally:
            # the test run in the game stays the project's (night test 07.10.: without its number the next start
            # parked it as an older run - the place was gone from the world until the next Build & Play)
            if run is not None:
                kept = Project(project_path)
                kept.meta["run"] = run
                kept.save_meta()
        project = Project(project_path)
        project.meta.pop("run", None)                   # (exported under the quest's own id)
    out = os.path.join(project_path, "build")
    dlc = os.path.join(out, "packed")
    if not os.path.isdir(os.path.join(dlc, "content")) or not os.listdir(os.path.join(dlc, "content")):
        # never built (any project can be exported now - Maxim 08.10.): built here, without the game
        from . import build as builder
        log("[export] Built first (it was not built yet)")
        builder.build(project_path, install=False, log=log)
        project = Project(project_path)
    if not os.path.isdir(os.path.join(dlc, "content")) or not os.listdir(os.path.join(dlc, "content")):
        raise ValueError("The quest could not be built. Please Build & Play it once")
    m = manifest(project, include_source, version, packs)
    m["tw3se"] = os.path.exists(os.path.join(dlc, "tw3se", "world.txt"))   # its world changes need TW3SE
    folder = export_folder(m)                           # (Maxim 06.10.: one folder, not four files loose)
    os.makedirs(folder, exist_ok=True)
    mark = os.path.join(folder, ID_FILE)
    if export_id(folder) != m["id"]:
        if os.name == "nt" and os.path.exists(mark):   # (Windows refuses to write over a hidden file)
            import ctypes
            ctypes.windll.kernel32.SetFileAttributesW(mark, 128)
        with open(mark, "w", encoding="utf-8") as f:
            f.write(m["id"])
        if os.name == "nt":                            # (hidden: the folder shows only what to upload)
            import ctypes
            ctypes.windll.kernel32.SetFileAttributesW(mark, 2)
    path = os.path.join(folder, os.path.basename(folder) + ".w3q")
    top = f"dlc/dlc{m['id']}/"
    log("[export] the quest file")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        # the manifest in the DLC: a quest put into the game by hand or by a mod manager is known as well
        z.writestr(top + QUEST_MANIFEST, yaml.safe_dump(m, sort_keys=False, allow_unicode=True))
        z.writestr(top + "README.txt", player_readme(m))      # for a player who unpacks it by hand
        # the signed history beside the manifest (provenance.py; the built bundle holds it too)
        from . import provenance
        provenance.note_safely(project_path, "export", force=True)
        hist = provenance.blob(project_path)
        z.writestr(top + "conjunction/" + provenance.FILE, hist)
        from . import timestamp                          # a public timestamp, only when turned on (timestamp.py)
        if timestamp.on():
            try:
                ots = timestamp.stamp(hist)
                z.writestr(top + "conjunction/history.ots", ots)
                keep = os.path.join(project_path, ".cj_history", "timestamps")
                os.makedirs(keep, exist_ok=True)
                with open(os.path.join(keep, f"{m['id']}-{m['version']}.ots"), "wb") as f:
                    f.write(ots)
                log("[export] public timestamp: the history's fingerprint sent to OpenTimestamps")
            except Exception as ex:                     # noqa: BLE001 - the export does not need it
                log(f"[export] no public timestamp ({ex})")
        for root, _, files in os.walk(dlc):
            for f in files:
                p = os.path.join(root, f)
                z.write(p, top + os.path.relpath(p, dlc).replace("\\", "/"))
        mod = os.path.join(out, "packed_mod")
        if os.path.isdir(mod):
            for root, _, files in os.walk(mod):
                for f in files:
                    p = os.path.join(root, f)
                    z.write(p, f"Mods/moddlc{m['id']}/" + os.path.relpath(p, mod).replace("\\", "/"))
        if include_source:
            for root, dirs, files in os.walk(project_path):
                dirs[:] = [d for d in dirs if d not in ("build", "versions")]
                for f in files:
                    p = os.path.join(root, f)
                    z.write(p, top + "conjunction_source/" + os.path.relpath(p, project_path).replace("\\", "/"))
    # the same file as a plain .zip: what Nexus takes and a mod manager installs (the .w3q: Conjunction's library)
    log("[export] the zip for mod managers")
    shutil.copy2(path, os.path.splitext(path)[0] + ".zip")
    # (no installer any more: Nexus put TW3SE in quarantine for one, 08.10. - its scanners take a self-made installer
    # for a dropper; the zip is what a player installs, by hand or with a mod manager)
    log("[export] the page text")
    page = os.path.splitext(path)[0] + ".nexus.txt"
    open(page, "w", encoding="utf-8").write(nexus_text(m))
    log(f"[export] {path}")
    log(f"[export] text for its download page: {page}")
    return path


SUITE_PAGE = "https://www.nexusmods.com/witcher3/mods/13916"     # Conjunction's own page (09.10.2026; 13908 and 13915 were deleted)
RUNTIME_PAGE = ""                       # the runtime has no page of its own: an optional file on Conjunction's
TW3SE_PAGE = "https://www.nexusmods.com/witcher3/mods/13837"     # TW3SE's (live 08.10.2026, new page after the quarantine)


def _link(url, text):
    return f"[url={url}]{text}[/url]" if url else text


def what(m):
    """quest or place mod: what an export is, in its texts."""
    return "place mod" if m.get("kind") == "place" else "quest"


GAME = "The Witcher 3 Remastered 5.0 or 5.01 (with Hearts of Stone and Blood and Wine)"   # (Maxim 08.10.: every remaster
# player has both expansions - no quest asks for them separately)


def runtime_page():
    """Where players get the Conjunction Runtime: its own page, else the files of Conjunction's page, where it is an
    optional file (Maxim 09.10.)."""
    return RUNTIME_PAGE or (f"{SUITE_PAGE}?tab=files" if SUITE_PAGE else "")


def needs(m):
    """What a player needs for the quest, in order: the game, TW3SE when it changes the world, the runtime for quests
    built before 08.10., the mods it takes things from, a quest it starts after -> [(text, url)]."""
    out = [(GAME, "")]
    if m.get("tw3se"):
        out.append((f"TW3SE (the {what(m)} changes the world)", TW3SE_PAGE))
    if int(m.get("runtime", 1)):
        out.append((f"Conjunction Runtime {m.get('runtime', 1)} or newer", runtime_page()))
    for p in m.get("packs") or []:
        used = [u.get("name") or u.get("ref") for u in p.get("used") or []]
        text = f"{p.get('name')} {p.get('version', '')}".strip()
        if used:
            text += f" (for: {', '.join(used[:6])}" + (", ..." if len(used) > 6 else "") + ")"
        out.append((text, p.get("url") or ""))
    if m.get("after"):
        out.append((f"the quest {m['after']} (this one starts after it)", ""))
    return out


def player_readme(m):
    """dlc<id>\\README.txt: what a player who installs the quest by hand needs to know."""
    lines = [f"{m.get('title')} {m.get('version', '')}".strip(), "",
             "Install: unpack into the game folder (the one with bin, content, dlc), or use a mod manager.",
             f"Remove: delete the folders dlc\\dlc{m.get('id')} and Mods\\moddlc{m.get('id')}.", "", "Needs:"]
    lines += [f"- {text}" + (f" ({url})" if url else "") for text, url in needs(m)]
    lines += ["", "Recommended: the Conjunction Runtime, an optional file of Conjunction" +
              (f" ({runtime_page()})" if runtime_page() else "") +
              ". It removes quests cleanly: it puts the game's world back as it was.", "",
              f"Made with {APP_NAME}" + (f" ({SUITE_PAGE})" if SUITE_PAGE else "") + ".", ""]
    return "\r\n".join(lines)


def nexus_text(m):
    """What a quest's download page should say (Nexus BBCode): its name, what it is, where it starts, what it needs
    (the same list Conjunction checks when a player drops the file in), the runtime as recommended."""
    st = m.get("starts") or {}
    lines = [f"[size=4][b]{m.get('title')}[/b][/size]", ""]
    if m.get("description"):
        lines += [m["description"], ""]
    if m.get("kind") == "place":
        lines += ["A place mod: its places are in the world from the first load.", ""]
    if st.get("text"):
        lines += [f"[b]Starts:[/b] {st['text']}" + (f" ({st['world']})" if st.get("world") else ""), ""]
    lines += ["[b]Requirements[/b]", "[list]"] + ["[*]" + _link(url, text) for text, url in needs(m)] + ["[/list]", ""]
    lines += ["[b]Recommended[/b]: " + _link(runtime_page(), "Conjunction Runtime") +
              f" (an optional file of Conjunction). It removes the {what(m)} cleanly: it puts the game's world back "
              "as it was.", "",
              "[b]Install[/b]: unpack the .zip into the game folder (the one with bin, content, dlc), or use a mod "
              "manager.", "",
              f"Made with {_link(SUITE_PAGE, APP_NAME)} {m.get('suite_version', '')}. Version {m.get('version')}."]
    return "\n".join(lines) + "\n"


QUEST_MANIFEST = "conjunction_quest.yml"


def manifest_name(z):
    """Where a .w3q keeps its manifest (in its DLC folder; older files: the root)."""
    names = z.namelist()
    if "manifest.yml" in names:
        return "manifest.yml"
    found = [n for n in names if n.count("/") == 2 and n.startswith("dlc/") and n.endswith("/" + QUEST_MANIFEST)]
    if not found:
        raise KeyError("no manifest")
    return found[0]


def read_manifest(path):
    with zipfile.ZipFile(path) as z:
        return yaml.safe_load(z.read(manifest_name(z))) or {}


def game_dir():
    return config.load().get("game", "")

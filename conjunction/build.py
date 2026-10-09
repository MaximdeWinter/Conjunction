"""Build a radish quest project into an installable DLC: encode -> link into the modkit depot -> analyze -> cook ->
pack -> metadatastore (the radish build.bat sequence, without batch files and without copy-paste).

    python -m conjunction.build <project dir> [--install]

A project dir holds `definition.quest/*.yml` (radish quest definition: production, structure, layers, ...).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

from . import config, idremap, plugins, w3strings
from .envhide import radish_repo


def window_titles(pid):
    """Titles of the visible windows of a process (wcc_lite opens an EULA dialog and waits forever)."""
    import ctypes
    import ctypes.wintypes as wt
    user32, titles = ctypes.windll.user32, []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        p = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value == pid and user32.IsWindowVisible(hwnd):
            buf = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, buf, 256)
            titles.append(buf.value)
        return True
    user32.EnumWindows(cb, 0)
    return titles


def run(cmd, cwd=None, log=print, harmless=()):
    log("  $ " + " ".join(f'"{c}"' if " " in c else c for c in cmd))
    import threading
    import time
    from .setup import keep_redkit_eula
    wcc = os.path.basename(cmd[0]).lower() == "wcc_lite.exe"
    if wcc:
        keep_redkit_eula()                  # accepted before (a DWORD wcc_lite itself cannot read back)
    proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace")
    lines = []
    reader = threading.Thread(target=lambda: lines.extend(proc.stdout.read().splitlines()), daemon=True)
    reader.start()                          # read while it runs: a full pipe would block wcc_lite
    t, asked = time.time(), None
    while proc.poll() is None:
        time.sleep(0.5)
        if asked is None and time.time() - t > 3 and any("EULA" in w for w in window_titles(proc.pid)):
            asked = time.time()             # the user accepts it (once) - it is their licence, never clicked for them
            log("  Accept the EULA of REDkit's wcc_lite. The build only continues once it is accepted")
        if asked and time.time() - asked > 600 and any("EULA" in w for w in window_titles(proc.pid)):
            proc.kill()
            raise RuntimeError("REDkit's wcc_lite waits for its EULA to be accepted. Please start the REDkit "
                               "once, accept the EULA and build again")
    reader.join(5)
    if wcc and keep_redkit_eula():
        log("  REDkit's EULA is accepted (wcc_lite will not ask again)")
    out = [ln for ln in lines if ln.strip()]
    for line in out[-8:]:
        log("    " + line)
    # harmless: ERROR lines a tool prints that are only hints (radish's lip sync: "no match" = tune it later)
    out = [ln for ln in out if not any(h in ln for h in harmless)] if harmless else out
    errors = [ln.strip() for ln in out if ln.strip().startswith("ERROR") or "[Error]" in ln]
    fatal = ("Failed to add seed file",)                # wcc_lite says so and still exits 0, having cooked almost nothing
    errors += [ln.strip() for ln in out if any(f in ln for f in fatal) and ln.strip() not in errors]
    if proc.returncode != 0 or any(ln.startswith("ERROR") for ln in out) or any(f in ln for ln in out for f in fatal):
        raise RuntimeError(f"{os.path.basename(cmd[0])} failed (exit {proc.returncode})"
                           + (":\n  " + "\n  ".join(errors[:5]) if errors else ""))
    return out


def production_idspace(defdir, default):
    """`strings-idspace:` of the production (Conjunction's own DLCs use their own, quests the configured one)."""
    for f in os.listdir(defdir):
        if f.startswith("prod.") and f.endswith(".yml"):
            for line in open(os.path.join(defdir, f), encoding="utf-8"):
                s = line.strip()
                if s.startswith("strings-idspace:"):
                    return int(s.split(":", 1)[1].strip().strip('"'))
    return default


def production_id(defdir):
    """The quest id from prod.quest-*.yml (`production: settings: id:`) - the DLC is named dlc<id>."""
    for f in os.listdir(defdir):
        if f.startswith("prod.") and f.endswith(".yml"):
            for line in open(os.path.join(defdir, f), encoding="utf-8"):
                s = line.strip()
                if s.startswith("id:"):
                    return s.split(":", 1)[1].strip().strip('"').lower()
    raise RuntimeError(f"no production id in {defdir}")


def merge_strings(csvs, target):
    """radish strings csv files (`;` comment lines, `id|key|key|text`) into one - the header of the first only."""
    out, header_done = [], False
    for c in csvs:
        if not os.path.exists(c):
            continue
        for line in open(c, encoding="utf-8").read().splitlines():
            if line.startswith(";"):
                if not header_done:
                    out.append(line)
                continue
            if line.strip():
                out.append(line)
        header_done = True
    open(target, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
    return target


OURS_ONLY = ("left", "outside", "inside", "journal", "period", "present", "combat", "all", "any", "nor")


def for_radish(defdir):
    """The definition as radish can parse it: a copy whose waits name Conjunction's own conditions (quest.conditions -
    an area now, a quest's state, the time of day, someone there, a fight, several; quest_encoder.condition writes
    them) as a stand-in fact. -> (the folder radish encodes, the blocks changed). Its quest file is not used: Conjunction's
    encoder writes it from `defdir`."""
    import tempfile
    import yaml
    stand_in = {"factdb": ["cj_radish_stand_in", "=", 1]}

    def plain(spec):
        return stand_in if any(k in spec for k in OURS_ONLY) else spec
    changed = []
    out = None
    for f in sorted(os.listdir(defdir)):
        if not (f.startswith("structure") and f.endswith(".yml")):
            continue
        d = yaml.safe_load(open(os.path.join(defdir, f), encoding="utf-8")) or {}
        mine = []
        for seg in (d.get("structure") or {}).values():
            for name, body in ((seg or {}).get("blocks") or {}).items():
                if not (name.startswith("waituntil.") and isinstance(body, dict)):
                    continue
                if isinstance(body.get("conditions"), dict):
                    for k, c in list(body["conditions"].items()):
                        if isinstance(c, dict) and plain(c) is not c:
                            body["conditions"][k] = plain(c)
                            mine.append(name)
                elif plain(body) is not body:
                    nxt = {k: v for k, v in body.items() if k.startswith("next")}
                    body.clear()
                    body.update(dict(stand_in, **nxt))
                    mine.append(name)
        if mine:
            if out is None:
                out = tempfile.mkdtemp(prefix="conjunction_radish_")
                shutil.copytree(defdir, os.path.join(out, os.path.basename(defdir)))
                out = os.path.join(out, os.path.basename(defdir))
            yaml.safe_dump(d, open(os.path.join(out, f), "w", encoding="utf-8"), sort_keys=False,
                           allow_unicode=True)
            changed += mine
    return (out or defdir), sorted(set(changed))


def check(project, log=print):
    """Quick check without cooking (seconds): generate, encode the quest and every scene - the errors a build
    would stop at, from radish, in plain words."""
    import tempfile
    from .project import Project
    cfg = config.load()
    project = os.path.abspath(project)
    tmp = tempfile.mkdtemp(prefix="conjunction_check_")
    try:
        defdir = Project(project).generate(os.path.join(tmp, "definition.quest"))
        os.makedirs(os.path.join(tmp, "uncooked"))
        os.makedirs(os.path.join(tmp, "scenes"))
        log("[check] quest")
        plain, mine = for_radish(defdir)
        if mine:
            log(f"[check] {len(mine)} wait{'s' * (len(mine) != 1)} with Conjunction's own conditions (its encoder "
                f"writes them): {', '.join(mine[:6])}")
        run([cfg["radish"] + r"\w2quest.exe", "--repo-dir", radish_repo(cfg), "--output-dir",
             os.path.join(tmp, "uncooked"), "--encode", plain], log=log)
        if plain != defdir:
            shutil.rmtree(os.path.dirname(plain), ignore_errors=True)
        minigames(tmp, os.path.join(tmp, "uncooked"), log)
        # the game's files the quest changes (a phase it is put into, scenes with another cutscene): they read back
        from .cr2w import CR2W
        changed = [os.path.join(r, n) for r, _d, files in os.walk(os.path.join(tmp, "definition.game")) for n in files]
        for fn in changed:
            data = open(fn, "rb").read()
            if CR2W(data).save() != data:
                raise RuntimeError(f"a changed game file does not read back: {os.path.basename(fn)}")
        if changed:
            log(f"[check] {len(changed)} game file{'s' * (len(changed) != 1)} changed - they read back")
        scenedefs = os.path.join(tmp, "definition.scenes")
        if os.path.isdir(scenedefs):
            for f in sorted(os.listdir(scenedefs)):
                if f.startswith("scene.") and f.endswith(".yml"):
                    log(f"[check] scene {f[6:-4]}")
                    run([cfg["radish"] + r"\w2scene.exe", "--repo-dir", cfg["radish"] + r"\repo.scenes",
                         "--output-dir", os.path.join(tmp, "scenes"), "--encode", f[:-4]], cwd=scenedefs, log=log)
        # the quest played through by a stand-in player (questsim): a way that stops is said here, not in the game
        from . import quest as Q
        from .questsim import playthrough
        proj = Project(project)
        q = proj.meta.get("quest") or {}
        if Q.has_quest(q):
            gen = Q.generate(proj)
            ok, what = playthrough(gen[0], q, proj.id, gen[1])
            log(f"[check] {'played' if ok else 'stuck'}: {what}")
        log("[check] ok")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def people_names(out, texts, keys, idspace):
    """The names people are shown by (definition.names.yml {tag: name}) into the DLC's strings: each found by the key
    cj_name_<tag> (lower case - mod/runtime/scripts/local/conjunction_names.ws asks for it), their ids from the top of the
    quest's range (radish counts up from its bottom). -> how many."""
    f = os.path.join(out, "definition.names.yml")
    if not os.path.exists(f):
        return 0
    import yaml
    names = yaml.safe_load(open(f, encoding="utf-8")) or {}
    top = 2110000000 + idspace * 1000 + 999
    for k, (tag, text) in enumerate(sorted(names.items())):
        texts[top - k] = str(text)
        keys[top - k] = w3strings.key_hash(f"cj_name_{tag}".lower())
    return len(names)


def game_files_changed(overrides):
    """The game's own files a build changes (the mod bundle's) -> their paths. Raises features.Off while the
    experimental features are off: terrain, a game quest, scene or cutscene changed (features.py)."""
    changed = sorted(os.path.relpath(os.path.join(r, f), overrides)
                     for r, _d, files in os.walk(overrides) for f in files) if os.path.isdir(overrides) else []
    from . import features
    if changed and not features.experimental():
        more = f" and {len(changed) - 3} more" if len(changed) > 3 else ""
        raise features.Off(f"This project changes game files ({', '.join(changed[:3])}{more}). That is an "
                           f"experimental feature (turn it on in Settings > General > Experimental)")
    return changed


def own_quest(defdir, uncooked, dlc, qid, cfg, log=print, scripts=None):
    """Our own quest encoder (quest_encoder.py) writes the quest file in place of radish's: radish's journal files
    give the objectives' GUIDs (until our journal encoder does). The game's blocks for the stand-ins are in it
    already. -> True when it wrote the file. Config `quest_encoder: radish` keeps radish's."""
    if cfg.get("quest_encoder", "ours") != "ours":
        return False
    import glob as _glob
    from . import quest_encoder as QE
    from .bundles import Depot
    dlcdir = os.path.join(uncooked, "dlc", dlc)
    target = os.path.join(dlcdir, "data", f"{qid}.w2quest")
    if not os.path.exists(target):
        return False
    # the journal files: ours (journal_encoder.py - the same objects and string ids as radish's) in place of radish's
    jy = os.path.join(defdir, "journals.yml")
    if os.path.exists(jy):
        import yaml
        from . import journal_encoder as JE
        settings = {}
        for f in os.listdir(defdir):
            if f.startswith("prod.") and f.endswith(".yml"):
                settings = (yaml.safe_load(open(os.path.join(defdir, f), encoding="utf-8")) or {}).get(
                    "production", {}).get("settings", {})
        files, _strings = JE.encode(yaml.safe_load(open(jy, encoding="utf-8")) or {},
                                    JE.Ctx(qid, dlc, settings.get("strings-idspace", cfg.get("idspace", 0)),
                                           settings.get("strings-idstart", 0), Depot().read(QE.TEMPLATE)))
        for path, data in files.items():
            dest = os.path.join(uncooked, path.replace("/", os.sep))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            open(dest + ".tmp", "wb").write(data)
            os.replace(dest + ".tmp", dest)
        log(f"[build] {qid}: journal encoded by Conjunction ({len(files)} files)")
    # the layer files: ours (layer_encoder.py - the same entities as radish's: places' objects, action points,
    # trigger areas, scene points, map pins) in place of radish's
    ly = os.path.join(defdir, "layers.yml")
    if os.path.exists(ly):
        import yaml
        from . import layer_encoder as LE
        from .envhide import radish_repo
        files = LE.encode(yaml.safe_load(open(ly, encoding="utf-8")) or {},
                          LE.Ctx(qid, dlc, Depot().read(QE.TEMPLATE), radish_repo(cfg)))
        for path, data in files.items():
            dest = os.path.join(uncooked, path)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            open(dest + ".tmp", "wb").write(data)
            os.replace(dest + ".tmp", dest)
        log(f"[build] {qid}: layers encoded by Conjunction ({len(files)} files)")
    journals = {}
    for jf in _glob.glob(os.path.join(dlcdir, "journal", "**", "*.journal"), recursive=True):
        journals["dlc/" + dlc + "/" + os.path.relpath(jf, dlcdir).replace("\\", "/")] = open(jf, "rb").read()
    suite = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    roots = [os.path.join(cfg["game"], "content", "content0", "scripts"),
             os.path.join(suite, "mod", "runtime", "scripts"), os.path.join(suite, "mod", "scripts")] + \
        ([scripts] if scripts else [])                  # (the quest's own copies: scriptlib.py)
    data = QE.encode(defdir, journals, QE.Ctx(qid, dlc, QE.script_functions(roots), Depot().read(QE.TEMPLATE)))
    tmp = target + ".tmp"
    open(tmp, "wb").write(data)
    os.replace(tmp, target)
    log(f"[build] {qid}: quest encoded by Conjunction ({len(data)} bytes)")
    return True


def apply_own_quest(project, uncooked, out, qid, log=print):
    """The own quest changed in the quest graph (vanilla_edit.own_quest_data) in place of what was encoded; what the
    quest board made kept beside (build/own_quest.encoded.w2quest: the graph's Revert). -> True when it replaced."""
    from .vanilla_edit import ENCODED, own_quest_data
    rel, data, _base = own_quest_data(project)
    keep = os.path.join(out, ENCODED)
    if data is not None and rel:
        target = os.path.join(uncooked, rel)
        shutil.copy(target, keep)
        open(target + ".tmp", "wb").write(data)
        os.replace(target + ".tmp", target)
        log(f"[build] {qid}: the quest as the quest graph left it ({len(data)} bytes)")
        return True
    if os.path.exists(keep):
        os.remove(keep)
    return False


def minigames(out, uncooked, log=print, own=False):
    """Gwent, fist fights, stopped lanes: the quest's stand-ins (definition.minigames.yml beside the definition) made
    the game's own blocks in the encoded quest (minigames.py). Script blocks get their parameters the way the
    remaster reads them (script_params.py - radish's alone arrive empty)."""
    from . import script_params
    from .cr2w import CR2W
    params = script_params.apply(uncooked)
    spec_file = os.path.join(out, "definition.minigames.yml")
    done = []
    if os.path.exists(spec_file):
        import yaml
        from . import minigames as M
        spec = yaml.safe_load(open(spec_file, encoding="utf-8")) or {}
        paths = {v["entity"]: v for v in spec.values() if v.get("game") == "path"}
        if paths:                                       # the ways of Follow steps into their path entities
            from .pathfollow import patch_paths
            log(f"[build] ways into {len(patch_paths(uncooked, paths))} path entities")
        if not own:                                     # (our encoder wrote the game's blocks at once)
            done = M.apply(uncooked, {k: v for k, v in spec.items() if v.get("game") != "path"})
    if params or done:
        for r, _d, files in os.walk(uncooked):
            for n in files:
                if n.endswith((".w2quest", ".w2phase")):
                    data = open(os.path.join(r, n), "rb").read()
                    if CR2W(data).save() != data:           # what was rewritten reads back
                        raise RuntimeError(f"{n} does not read back after its blocks were written")
    if params:
        log(f"[build] script blocks with their parameters: {params}")
    if done:
        log(f"[build] the game's own blocks: {', '.join(done)}")


MISSING_RE = re.compile(r"Hardlinked resource '([^']+)' for parent resource")


def write_seed(dlc_dir, seed):
    """The cook's list of files (what 'wcc_lite analyze r4dlc' writes, 17 s of starting it saved): every file of the
    uncooked DLC in one bundle, the .reddlc with its chunk."""
    import json
    root = os.path.dirname(os.path.dirname(dlc_dir))           # (paths start at dlc\\)
    files = []
    for d, _s, fs in os.walk(dlc_dir):
        for f in fs:
            rel = os.path.relpath(os.path.join(d, f), root)
            e = {"path": rel, "bundle": "blob"}
            if f.lower().endswith(".reddlc"):
                e["chunks"] = ["dlc"]
            files.append(e)
    files.sort(key=lambda e: e["path"].lower())
    json.dump({"files": files}, open(seed, "w", encoding="utf-8"), indent=4)


def pack_and_index(src, content, wcc, bindir, log=print):
    """The cooked files into a bundle and its metadata.store - by Conjunction (packer.py, metastore.py: well under a
    second; wcc_lite took 21 s to pack and 26 s for the store, most of it starting itself - 02.10.). wcc_lite when
    CJ_WCC_PACK is set or Conjunction's way fails."""
    # a cooked mesh comes with buffer files (<mesh>.1.buffer): wcc_lite puts them into a bundle of their own
    # (buffers0.bundle); Conjunction's packer does not, and the store check fails ("BUFFERS ARE NOT AT THE END OF THE
    # BUNDLE" - a content pack's furniture, 04.10.)
    buffers = any(f.endswith(".buffer") for _d, _s, fs in os.walk(src) for f in fs)
    if not os.environ.get("CJ_WCC_PACK") and not buffers:
        try:
            from . import metastore, packer
            os.makedirs(content, exist_ok=True)
            bundle = packer.pack(src, content)
            store = metastore.build([(os.path.basename(bundle), bundle)])
            with open(os.path.join(content, "metadata.store"), "wb") as f:
                f.write(store)
            log(f"[build] packed and indexed by Conjunction ({os.path.getsize(bundle)} bytes)")
            return
        except Exception as ex:                         # noqa: BLE001 - wcc_lite does it then
            log(f"[build] Conjunction's packer failed ({ex}), wcc_lite packs instead")
    run([wcc, "pack", f"-dir={src}", f"-outdir={content}"], cwd=bindir, log=log)
    run([wcc, "metadatastore", f"-path={content}"], cwd=bindir, log=log)


def _mark_seed(project):
    """The project's mark seed (marks.py) or None (a project made before marks, a radish folder)."""
    if not project or not os.path.isfile(os.path.join(project, "project.yml")):
        return None
    import yaml
    from . import marks
    return marks.project_seed(yaml.safe_load(open(os.path.join(project, "project.yml"), encoding="utf-8")))


def build_tools(cfg):
    """The tools a build used, for its history step: Conjunction and its plug-ins, radish, REDkit's wcc_lite."""
    from . import provenance
    out = provenance.tools()
    if cfg.get("radish"):
        import re
        from . import radish_tools
        v = re.search(r"v\d{4}-\d\d-\d\d", radish_tools.ZIP_NAME)
        out.append("radish modding tools " + (v.group(0) if v else ""))
    if cfg.get("wcc"):
        out.append("REDkit wcc_lite")
    return out


def need_redkit(cfg=None):
    """Building cooks with REDkit's wcc_lite: without it, one plain message (the start does not ask for it)."""
    cfg = cfg or config.load()
    if not os.path.isfile(cfg.get("wcc") or ""):
        raise RuntimeError("REDkit is missing. Please install The Witcher 3 REDkit (free on Steam or GOG) and set "
                           "its folder in Settings > Game")


def build(project, install=False, log=print, test_from=None):
    need_redkit()
    project = os.path.abspath(project)
    out = os.path.join(project, "build")
    if not os.path.exists(os.path.join(project, "project.yml")):
        return build_dlc(os.path.join(project, "definition.quest"), out, install, log, project=project)
    # a conjunction project: the radish definition is generated from its places. What REDkit cannot cook (a resource
    # it does not find) is left out with a note and the build runs again - one gap must not stop a whole quest.
    from .project import Project
    skip = set()
    tries = 40                                      # every try may bring more of the game's files (links)
    for attempt in range(tries):
        proj = Project(project)
        proj.test_from = test_from
        if test_from:
            log(f"[build] a test: the quest starts at {test_from}")
        defdir = proj.generate(os.path.join(out, "definition.quest"), skip_templates=skip)
        for what in getattr(proj, "skipped", []):
            log(f"[build] left out: {what}")
        for what in getattr(proj, "notes", []):
            log(f"[build] {what}")
        if attempt:
            log(f"[build] again (try {attempt + 1})")
        lines = []

        def keep(line):
            lines.append(line)
            log(line)
        try:
            extra = getattr(proj, "extra_resources", None) or None
            return build_dlc(defdir, out, install, keep, project=project, extra=extra,
                             collision_cache=bool(extra and any(r.endswith(".w2mesh") for r in extra)))
        except RuntimeError:
            missing = {m.group(1).lower() for ln in lines for m in MISSING_RE.finditer(ln)}
            linked = link_from_depot(missing, log)
            unfound = missing - linked
            new = _templates_using(proj, unfound) - skip
            if not (linked or new) or attempt == tries - 1:
                raise
            for t in sorted(new):
                log(f"[build] not in REDkit's depot either: {', '.join(sorted(unfound))} - left out: {t}")
            skip |= new


def readable_items(uncooked, dlc, project=None):
    """radish writes the quest's own items as misc things: those with a text are letters and books (readable quest
    items), those without are plain quest items (marked in the inventory, not for sale)."""
    import re
    path = os.path.join(uncooked, "dlc", dlc, "data", "gameplay", "items", "def_item_quest.xml")
    if not os.path.exists(path):
        return
    plain, icons = set(), {}
    if isinstance(project, str):                    # the build knows the project by its folder
        from .project import Project
        project = Project(project)
    if project is not None:
        qid = str(project.id).lower()
        own = (project.meta.get("quest") or {}).get("items") or {}
        plain = {f"{qid}_own_{iid}".lower() for iid, d in own.items() if not (d or {}).get("text")}
        # an item made from a game item keeps that one's icon (radish gives every own item a scroll)
        based = {f"{qid}_own_{iid}".lower(): d["base"] for iid, d in own.items() if (d or {}).get("base")}
        if based:
            try:
                from .assets import Assets
                db = Assets()
                icons = {k: (db.item(b) or {}).get("icon") for k, b in based.items()}
            except Exception:                           # noqa: BLE001 - no catalog: the scroll stays
                icons = {}

    def one(m):
        block = m.group(0)
        name = re.search(r'<item name="([^"]+)"', block).group(1).lower()
        if icons.get(name):
            block = re.sub(r'icon_path="[^"]*"', f'icon_path="{icons[name]}"', block)
        if name in plain:
            return block.replace("<!--<tags></tags>-->", "<tags>Quest</tags>")
        return block.replace('category="misc"', 'category="book"').replace(
            "<!--<tags></tags>-->", "<tags>ReadableItem, Quest</tags>")
    text = open(path, encoding="utf-16").read()
    text = re.sub(r"<item name=.*?</item>", one, text, flags=re.S)
    open(path, "w", encoding="utf-16").write(text)


def xml_utf8(uncooked, dlc):
    """radish writes the DLC's definitions (own items, rewards) as UTF-16; the remaster reads them only as UTF-8 with
    a BOM, as its own are - an own item was unknown to the game (AddAnItem gave 0). -> the files changed."""
    done = []
    for root, _dirs, files in os.walk(os.path.join(uncooked, "dlc", dlc)):
        for n in files:
            if not n.lower().endswith(".xml"):
                continue
            p = os.path.join(root, n)
            raw = open(p, "rb").read()
            if raw[:2] not in (b"\xff\xfe", b"\xfe\xff"):
                continue
            text = raw.decode("utf-16")
            text = re.sub(r'(<\?xml[^>]*encoding=")UTF-16(")', r"\1UTF-8\2", text, count=1, flags=re.I)
            open(p, "w", encoding="utf-8-sig", newline="").write(text)
            done.append(n)
    return done


def prelink(uncooked, cfg, log=print):
    """Before cooking: every game file our layers, templates and communities point at - and what the game's templates
    among them point at (a chest template -> its meshes) - linked from REDkit's depot at once (wcc_lite names only one
    missing file a try: a camp of twenty things took twenty tries)."""
    from .assets import _cr2w_parts
    r4data = os.path.join(cfg["redkit"], "r4data")
    depot = uncook_depot(cfg)

    def imports(data):
        try:
            return {path.lower() for part in _cr2w_parts(data) for path, _cls, _fl in part.imports if path}
        except Exception:                               # noqa: BLE001 - not a CR2W we can read
            return set()
    todo = set()
    for root, _dirs, files in os.walk(uncooked):
        for f in files:
            if f.endswith((".w2l", ".w2ent", ".w2comm")):
                todo |= imports(open(os.path.join(root, f), "rb").read())
    wanted, seen = set(), set()
    for _depth in range(3):                             # a layer -> a template -> its includes and meshes
        nxt = set()
        for rel in todo - seen:
            seen.add(rel)
            if rel.startswith("dlc\\"):
                continue
            if not os.path.exists(os.path.join(r4data, rel)):
                wanted.add(rel)
            if rel.endswith(".w2ent"):
                for base in (r4data, depot):
                    if base and os.path.isfile(os.path.join(base, rel)):
                        nxt |= imports(open(os.path.join(base, rel), "rb").read())
                        break
        todo = nxt
    if wanted:
        link_from_depot(wanted, log)


def link_from_depot(resources, log=print):
    """The game's files wcc_lite misses: hard links from REDkit's uncooked depot into r4data. Returns those linked."""
    cfg = config.load()
    depot = uncook_depot(cfg)
    if not depot:
        return set()
    r4data = os.path.join(cfg["redkit"], "r4data")
    done = set()
    for rel in resources:
        src, dst = os.path.join(depot, rel), os.path.join(r4data, rel)
        if not os.path.isfile(src):
            continue
        if not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            try:
                os.link(src, dst)
            except OSError:
                shutil.copy2(src, dst)              # another drive: a copy
        done.add(rel)
    if done:
        log(f"[build] {len(done)} of the game's files from REDkit's depot into r4data: {', '.join(sorted(done)[:4])}"
            + (" ..." if len(done) > 4 else ""))
    return done


def _templates_using(proj, resources):
    """Templates of the project that are, or use, one of these resources (their meshes and includes)."""
    from .assets import read_template
    from .bundles import Depot
    from . import meshlib
    depot = Depot()
    mesh_of = meshlib.reverse_index()
    out = set()
    for p in proj.places.values():
        for o in p.get("objects", []):
            t = o["template"].lower()
            uses = {t, mesh_of.get(t, "")}
            if depot.exists(t):
                try:
                    info = read_template(depot.read(t)) or {}
                    uses |= set(info.get("meshes", [])) | set(info.get("includes", []))
                except Exception:                       # noqa: BLE001
                    pass
            if uses & resources:
                out.add(t)
    return out


def uncook_depot(cfg=None):
    """The folder REDkit uncooked the game into (its editor's uncookPath; config "uncook_depot" wins), ending in a
    backslash - REDkit 5's wcc_lite finds the game's own files there (-uncookDir), not in r4data."""
    cfg = cfg or config.load()
    path = cfg.get("uncook_depot")
    if not path:
        ini = os.path.join(cfg["redkit"], "bin", "r4LavaEditor2.ini")
        try:
            for line in open(ini, encoding="utf-8", errors="replace"):
                if line.lower().startswith("uncookpath="):
                    path = line.split("=", 1)[1].strip()
                    break
        except OSError:
            return None
    if not path or not os.path.isdir(path):
        return None
    return path.rstrip("\\/") + "\\"


def plugin_files(project, dlc_dir, dlc, log=print):
    """The plug-ins' part of a build before cooking: their uncooked steps (api.add_uncooked_step - what they write
    below the DLC's folder is cooked with it: own .w2anims, cutscenes) and their CSV rows (api.add_csv_rows): one
    file per path in the DLC, its header once, every plug-in's rows after it (rows there already: not twice)."""
    from . import plugins
    for step in plugins.get().uncooked_steps():
        step(project, dlc_dir, dlc, log)
    merged = {}
    for fn in plugins.get().csv_rows():
        for rel, (header, rows) in (fn(project) or {}).items():
            have = merged.setdefault(rel.replace("/", "\\"), [header, []])
            have[1] += [r for r in rows if r not in have[1]]
    for rel, (header, rows) in merged.items():
        target = os.path.join(dlc_dir, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        lines = open(target, encoding="utf-8").read().splitlines() if os.path.exists(target) else [header]
        lines += [r for r in rows if r not in lines]
        open(target + ".tmp", "w", encoding="utf-8", newline="\r\n").write("\n".join(lines) + "\n")
        os.replace(target + ".tmp", target)
        log(f"[build] {dlc}: {len(rows)} rows of the plug-ins in {rel}")


def install_mod(packed_mod, game, dlc, log=print):
    """The mod bundle with the game's files a quest changes -> <game>\\Mods\\mod<dlc>; none (any more): an old one
    goes, so no stale override stays."""
    target = os.path.join(game, "Mods", f"mod{dlc}")
    if os.path.exists(target):
        shutil.rmtree(target)
    if os.path.isdir(os.path.join(packed_mod, "content")) and os.listdir(os.path.join(packed_mod, "content")):
        shutil.copytree(packed_mod, target)
        log(f"[build] the game's files it changes -> {target}")
    return target


def wide_strings(project, qid):
    """The first of the quest's own 1000 text ids in the wide field (idremap.py) - None for Conjunction's own DLCs and
    when a project turns it off (`strings_wide: false`)."""
    if isinstance(project, str):                    # (build_dlc gets the project's folder)
        if not os.path.exists(os.path.join(project, "project.yml")):
            return None                             # a plain radish definition: radish's ids as they are
        from .project import Project
        project = Project(project)
    if project is None or project.meta.get("strings_wide") is False:
        return None
    return idremap.wide_base(qid, 1000, str(project.meta.get("strings_salt", "")))


def build_dlc(defdir, out, install=False, log=print, project=None, extra=None, after_encode=None,
              collision_cache=False):
    """A radish definition folder -> the DLC dlc<id> (scenes from <out>/definition.scenes), optionally installed.
    `extra`: {depot path inside the DLC: source file} - ready-made uncooked resources (the gizmo meshes).
    `after_encode(uncooked, dlc)`: changes to radish's output before cooking (a content pack's items)."""
    cfg = config.load()
    qid = production_id(defdir)
    dlc = f"dlc{qid}"
    uncooked, cooked, packed = (os.path.join(out, d) for d in ("uncooked", "cooked", "packed"))
    overrides, packed_mod = os.path.join(out, "overrides"), os.path.join(out, "packed_mod")
    for d in (cooked, packed, overrides, packed_mod):
        if os.path.exists(d):
            shutil.rmtree(d)
    for d in (uncooked, cooked, os.path.join(packed, "content")):
        os.makedirs(d, exist_ok=True)

    # the runtime functions the quest calls: its own copies, named after it (scriptlib.py - every quest runs without
    # the runtime); the definition files call those names from here on
    from . import scriptlib
    scripts = os.path.join(packed_mod, "content", "scripts", "local")
    try:
        scriptlib.apply(out, qid, scripts, log)
    except scriptlib.RuntimeOnly as ex:
        raise RuntimeError(f"the quest calls something only the Conjunction Runtime can do: {ex}") from None

    log(f"[build] {qid}: encode quest")
    plain, mine = for_radish(defdir)
    if mine and cfg.get("quest_encoder", "ours") != "ours":
        raise RuntimeError(f"these waits need Conjunction's quest encoder (config quest_encoder: radish): "
                           f"{', '.join(mine[:6])}")
    run([cfg["radish"] + r"\w2quest.exe", "--repo-dir", radish_repo(cfg), "--output-dir", uncooked,
         "--encode", plain], log=log)
    if plain != defdir:                                 # (radish's copy: done with)
        shutil.rmtree(os.path.dirname(plain), ignore_errors=True)
    own = own_quest(defdir, uncooked, dlc, qid, cfg, log, scripts=scripts)
    readable_items(uncooked, dlc, project)
    utf8 = xml_utf8(uncooked, dlc)
    if utf8:
        log(f"[build] {qid}: definitions as UTF-8 (the remaster reads no other): {', '.join(utf8)}")
    minigames(out, uncooked, log, own=own)
    if after_encode:
        after_encode(uncooked, dlc)
    # the same GUIDs on every build: a save that is in the quest resumes it after a rebuild (stable_ids.py)
    # - derived from the maker's mark seed when the project has one (marks.py: the maker's mark in every GUID)
    from .stable_ids import stabilize
    stabilize(os.path.join(uncooked, "dlc", dlc), qid, log=log, seed=_mark_seed(project))
    if project:                                         # the own quest as the quest graph left it
        apply_own_quest(project, uncooked, out, qid, log)
    for rel, source in (extra or {}).items():
        target = os.path.join(uncooked, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy(source, target)

    if project:                                         # plug-ins: their own files cooked with the DLC, CSV rows
        plugin_files(project, os.path.join(uncooked, "dlc", dlc), dlc, log)

    # wcc_lite cooks from its depot: our uncooked DLC is linked in as r4data\dlc\<dlc> (additive, own name)
    link = os.path.join(cfg["redkit"], "r4data", "dlc", dlc)
    src = os.path.join(uncooked, "dlc", dlc)
    # the junction must point at THIS project's files: two projects with the same id (an example and its copy)
    # share the name, and a junction left from the other one made wcc cook stale files
    if os.path.lexists(link) and os.path.normcase(os.path.realpath(link)) != os.path.normcase(os.path.realpath(src)):
        os.rmdir(link)                                  # removes the junction only, not what it points at
    if not os.path.exists(link):
        subprocess.run(["cmd", "/c", "mklink", "/J", link, src], check=True, capture_output=True)
    wcc = cfg["wcc"]
    bindir = os.path.dirname(wcc)
    seed = os.path.join(out, "seed.files")
    prelink(uncooked, cfg, log)
    log(f"[build] {qid}: analyze, cook")
    # REDkit 5: the game's files are in the uncooked depot; wcc_lite's -uncookDir does not reach the cook
    # (checked 29.09.) - missing files are linked into r4data instead (build: link_from_depot)
    extra_args = []
    if os.environ.get("CJ_WCC_ANALYZE"):           # (the old way, to compare)
        run([wcc, "analyze", "r4dlc", f"-dlc=dlc\\{dlc}\\{dlc}.reddlc", f"-out={seed}"] + extra_args, cwd=bindir,
            log=log)
    else:
        write_seed(os.path.join(uncooked, "dlc", dlc), seed)
    # the quest names its scenes, but they are encoded straight into the cooked DLC below; one seed entry missing from
    # the depot makes wcc_lite drop the whole seed (only a file or two get cooked - no quest, no layers)
    import json
    data = json.load(open(seed, encoding="utf-8"))
    data["files"] = [e for e in data["files"] if os.path.exists(os.path.join(uncooked, e["path"]))]
    # wcc_lite does not follow references here: ready-made resources of the DLC itself must be in the seed
    listed = {e["path"].lower() for e in data["files"]}
    data["files"] += [{"path": rel.replace("/", "\\"), "bundle": "blob"} for rel in (extra or {})
                      if rel.replace("/", "\\").lower() not in listed]
    json.dump(data, open(seed, "w", encoding="utf-8"), indent=4)
    run([wcc, "cook", "-platform=pc", f"-trimdir=dlc\\{dlc}", f"-seed={seed}", f"-outdir={cooked}"] + extra_args,
        cwd=bindir, log=log)
    db = os.path.join(cooked, "cook.db")
    if os.path.exists(db):
        os.replace(db, os.path.join(out, "cook.db"))           # must not be packed
    # the cook dropped the parameters of the quest's own script functions (it does not know the mod's scripts)
    from . import script_params
    back = script_params.restore(uncooked, cooked)
    if back:
        log(f"[build] {qid}: script parameters put back after cooking: {back}")
    # dialogue scenes: encoded straight into the cooked DLC (as radish does), their texts join the quest's
    scene_csvs = []
    scenedefs = os.path.join(out, "definition.scenes")
    if os.path.isdir(scenedefs):
        tmp = os.path.join(out, "scenes")
        if os.path.exists(tmp):
            shutil.rmtree(tmp)
        os.makedirs(tmp)
        target_dir = os.path.join(cooked, "dlc", dlc, "data", "scenes")
        os.makedirs(target_dir, exist_ok=True)
        import yaml
        tf = os.path.join(scenedefs, "targets.yml")
        targets = yaml.safe_load(open(tf, encoding="utf-8")) if os.path.exists(tf) else {}
        for f in sorted(os.listdir(scenedefs)):
            if f.startswith("scene.") and f.endswith(".yml"):
                name = f[:-4]
                log(f"[build] {qid}: scene {name[6:]}")
                run([cfg["radish"] + r"\w2scene.exe", "--repo-dir", cfg["radish"] + r"\repo.scenes", "--output-dir",
                     tmp, "--encode", name], cwd=scenedefs, log=log)
                dest = os.path.join(target_dir, name[6:] + ".w2scene")
                if targets.get(name[6:]):           # a swapped game scene: under the game's own path, in the mod
                    dest = os.path.join(overrides, targets[name[6:]].replace("/", "\\"))
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copy(os.path.join(tmp, name + ".w2scene"), dest)
                scene_csvs.append(os.path.join(tmp, name + ".w3strings-csv"))
    keyed = os.path.join(out, "definition.strings.csv")     # texts by key (notices)
    if os.path.exists(keyed):
        scene_csvs.append(keyed)
    # game files changed for the quest (a game quest's phase it is put into): cooked already, under their path, in
    # the mod bundle
    gamedir = os.path.join(out, "definition.game")
    for root, _dirs, files in os.walk(gamedir):
        for name in files:
            rel = os.path.relpath(os.path.join(root, name), gamedir)
            os.makedirs(os.path.dirname(os.path.join(overrides, rel)), exist_ok=True)
            shutil.copy(os.path.join(root, name), os.path.join(overrides, rel))
            log(f"[build] {qid}: game file changed: {rel}")
    # own recordings: audio, lip sync and the speech file (one for every game language: the author recorded one)
    speech_def = os.path.join(out, "definition.speech.yml")
    if os.path.exists(speech_def):
        import yaml
        from . import speech
        lines = yaml.safe_load(open(speech_def, encoding="utf-8"))["speech"]
        log(f"[build] {qid}: {len(lines)} own voice lines")
        work = os.path.join(out, "speech")
        csv = speech.build(lines, work, os.path.join(packed, "content"), "en", log)
        scene_csvs.append(csv)
        made = open(os.path.join(packed, "content", "enpc.w3speech"), "rb").read()
        from . import w3speech
        _v, _lang, spoken = w3speech.read(made)
        for n in os.listdir(os.path.join(cfg["game"], "content", "content0")):
            lang = n[:-len("pc.w3speech")]
            if n.endswith("pc.w3speech") and lang != "en":
                # every language file with its own keys (as the game's); the author recorded one language
                data = w3speech.write_v164(lang, spoken) if lang in w3speech.LANGS and _v == 164 else made
                open(os.path.join(packed, "content", n), "wb").write(data)
    for step in (plugins.get().build_steps() if project else []):
        step(project, out, log)
    # text ids of its own, far from every other quest's (idremap.py): the encoded files now, strings and speech below
    space = production_idspace(defdir, cfg.get("idspace", 9999))
    lo = 2110000000 + space * 1000
    wide = wide_strings(project, qid)
    if wide is not None:
        moved = sum(idremap.remap_tree(d, lo, lo + 999, wide) for d in (cooked, overrides) if os.path.isdir(d))
        log(f"[build] {qid}: text ids moved to {wide}..{wide + 999} ({moved} in the encoded files)")
    if project:                                         # the signed history goes into the bundle (provenance.py)
        from . import provenance
        provenance.note_safely(project, "edit")
        provenance.note_safely(project, "build", force=True, tools_used=build_tools(cfg))
        hist = os.path.join(cooked, "dlc", dlc, "conjunction", provenance.FILE)
        os.makedirs(os.path.dirname(hist), exist_ok=True)
        with open(hist, "wb") as f:
            f.write(provenance.blob(project))
    log(f"[build] {qid}: pack, metadatastore")
    pack_and_index(cooked, os.path.join(packed, "content"), wcc, bindir, log)
    if collision_cache:                     # meshes with collision (a planted tree's): their shapes for the physics
        log(f"[build] {qid}: collision cache")
        content = os.path.join(packed, "content")
        run([wcc, "buildcache", "physics", "-platform=pc", f"-db={os.path.join(out, 'cook.db')}",
             f"-out={os.path.join(content, 'collision.cache')}"], cwd=bindir, log=log)
        run([wcc, "metadatastore", f"-path={content}"], cwd=bindir, log=log)
    # terrain painted in the editor (terrain.yml): its tiles replace the game's (the mod bundle), their collision
    # goes into the mod's collision.cache (written before the pack: the store then lists it)
    from . import terrain
    if project and os.path.exists(os.path.join(project, terrain.FILE)):
        terrain.build_into(project, overrides, os.path.join(packed_mod, "content"), log)
    # the game's quest files edited in the quest graph (vanilla_edit.py): under their own paths, in the mod bundle
    from .vanilla_edit import GAME_FILES
    own = os.path.join(project, GAME_FILES) if project else None
    for root, _dirs, files in os.walk(own) if own and os.path.isdir(own) else ():
        for name in files:
            if name.endswith(".tmp") or (root == own and name.startswith("own_quest.")):
                continue                                # (the own quest goes into the DLC, above)
            rel = os.path.relpath(os.path.join(root, name), own)
            os.makedirs(os.path.dirname(os.path.join(overrides, rel)), exist_ok=True)
            shutil.copy(os.path.join(root, name), os.path.join(overrides, rel))
            log(f"[build] {qid}: game quest file edited: {rel}")
    if game_files_changed(overrides):
        log(f"[build] {qid}: the game's files it changes - a mod bundle")
        os.makedirs(os.path.join(packed_mod, "content"), exist_ok=True)
        pack_and_index(overrides, os.path.join(packed_mod, "content"), wcc, bindir, log)
    strings = os.path.join(uncooked, "queststrings.csv")
    if scene_csvs:
        strings = merge_strings([strings] + scene_csvs, os.path.join(uncooked, "allstrings.csv"))
    if os.path.exists(strings):
        log(f"[build] {qid}: strings")
        run([cfg["radish"] + r"\w3strings.exe", "--encode", strings, "--id-space",
             str(production_idspace(defdir, cfg.get("idspace", 9999)))],
            log=log)
        base = os.path.basename(strings)
        for f in os.listdir(uncooked):
            if f.startswith(base + ".") and f.endswith(".w3strings"):
                # one text for every game language (a missing language file shows empty journal entries)
                langs = {os.path.splitext(n)[0] for n in os.listdir(os.path.join(cfg["game"], "content", "content0"))
                         if n.endswith(".w3strings")} or {"en"}
                # radish writes v162 with en's key; the remaster (5.0) loads only v164 - each language its own
                version, _head, texts, keys = w3strings.read(open(os.path.join(uncooked, f), "rb").read())
                named = people_names(out, texts, keys, production_idspace(defdir, cfg.get("idspace", 9999)))
                if named:
                    log(f"[build] {qid}: {named} people with names of their own")
                if wide is not None:
                    texts = idremap.remap_ids(texts, lo, lo + 999, wide)
                    keys = idremap.remap_ids(keys, lo, lo + 999, wide)
                for lang in sorted(langs):
                    data = w3strings.write_v164(lang if lang in w3strings.LANGS else "en", texts, hashes=keys)
                    open(os.path.join(packed, "content", f"{lang}.w3strings"), "wb").write(data)
                log(f"[build] {qid}: {len(texts)} strings as v164 in {len(langs)} languages")
    if wide is not None:
        content_dir = os.path.join(packed, "content")
        for n in sorted(os.listdir(content_dir)):
            if n.endswith("pc.w3speech"):
                from . import w3speech
                f = os.path.join(content_dir, n)
                _v, lang, spoken = w3speech.read(open(f, "rb").read())
                spoken = [(wide + (sid - lo) if lo <= sid <= lo + 999 else sid, a, d, ls) for sid, a, d, ls in spoken]
                open(f, "wb").write(w3speech.write_v164(lang, spoken))
    if project and os.path.exists(os.path.join(project, "project.yml")):
        from . import worldchanges
        from .project import Project
        worldchanges.write(project, qid, Project(project).meta.get("quest") or {}, packed, log)
    target = os.path.join(cfg["game"], "dlc", dlc)
    if install:
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.copytree(packed, target)
        log(f"[build] installed -> {target}")
        mod_target = install_mod(packed_mod, cfg["game"], dlc, log)
        if project and os.path.exists(os.path.join(project, "project.yml")):
            from . import in_game                       # (whose it is: the gate before a start knows it by this)
            from .project import Project
            base = Project(project).base_id
            for folder in (target, mod_target):
                if os.path.isdir(folder):
                    in_game.mark(folder, project, dlc[3:], base)
        if project and os.path.exists(os.path.join(project, "project.yml")):
            from .project import snapshot                # (the project as this run was built: a version)
            snapshot(project, dlc[3:])
        if project and os.path.exists(os.path.join(project, "project.yml")):
            from . import in_game                       # (only this project in the world: the others parked)
            in_game.park_others(project, log, cfg["game"])
    else:
        log(f"[build] ready (not installed): {packed}")
    return packed


def main():
    # the tools print phonemes and names in any script: a console or file in the system's code page must not stop
    # the build over one character (02.10.: 'ə' of the lip sync tool)
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--install", action="store_true", help="copy into <game>\\dlc (takes effect at the next game start)")
    ap.add_argument("--check", action="store_true", help="only encode (seconds, no cooking): does radish accept it?")
    args = ap.parse_args()
    try:
        if args.check:
            check(args.project)
            return
        build(args.project, args.install)
    except RuntimeError as e:
        print(f"[build] {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

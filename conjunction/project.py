"""A conjunction project = one mod of whatever is made in it: a quest, places, painted terrain, changes to the world -
nothing of it chosen up front (Maxim 04.10.: "man entscheidet nicht am anfang was man tun will"). Places belong to
it: a place exists in the world only because the project shows it.

    <project>/project.yml         id, name, description (and the quest, when there is one)
    <project>/places/<place>.yml  world, visible (when the quest shows it), objects (template, pos, rot)
    <project>/terrain.yml         the terrain painted in the editor (terrain.py)

`generate()` turns it into a radish quest definition (production, layers, structure); `apply_change()` takes the
editor's report lines from the game (gamelink) and keeps the place files up to date (nothing to copy by hand).
"""
import glob
import os
import shutil

import yaml

from . import config
from . import paths

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECTS = paths.PROJECTS


GRAPH_JOURNAL = "graph_journal.yml"      # objectives made in the quest graph: {"objectives": [{"id", "caption"}]}


def graph_objectives(path):
    import yaml
    f = os.path.join(path, GRAPH_JOURNAL)
    try:
        return (yaml.safe_load(open(f, encoding="utf-8")) or {}).get("objectives") or []
    except OSError:
        return []


def add_graph_objectives(path, journals):
    """The quest graph's objectives after the quest board's (their keys sort last: the board's keep their order)."""
    extra = graph_objectives(path)
    quests = (journals or {}).get("quests") or {}
    if not extra or not quests:
        return
    q = next(iter(quests.values()))
    main = q.setdefault("instructions", {}).setdefault("main", [])
    have = {k for item in main if isinstance(item, dict) for k in item}
    for o in extra:
        if o["id"] not in have:
            main.append({o["id"]: {"caption": o["caption"]}})


def new_graph_objective(path, caption):
    """An objective more, made in the quest graph (in the journal from the next build on). -> its id."""
    import yaml
    have = graph_objectives(path)
    oid = f"zgraph{len(have) + 1}"
    have.append({"id": oid, "caption": caption})
    f = os.path.join(path, GRAPH_JOURNAL)
    yaml.safe_dump({"objectives": have}, open(f + ".tmp", "w", encoding="utf-8"), allow_unicode=True)
    os.replace(f + ".tmp", f)
    return oid


def is_example(path):
    """Is `path` one of Conjunction's examples - by any way to it (a junction, another drive letter)?"""
    examples = os.path.join(os.path.dirname(HERE), "examples")
    return os.path.normcase(os.path.realpath(os.path.dirname(os.path.abspath(path)))) == \
        os.path.normcase(os.path.realpath(examples))


def recent():
    """The projects opened last (newest first), those that still exist - then every other quest in
    Documents\\Conjunction (newest first): one made outside the editor shows up too."""
    cfg = config.load()
    out = [p for p in cfg.get("recent", []) if os.path.exists(os.path.join(p, "project.yml"))
           and not is_example(p)]                  # examples open as own copies
    seen = {os.path.normcase(os.path.abspath(p)) for p in out}
    others = [os.path.join(PROJECTS, d) for d in (os.listdir(PROJECTS) if os.path.isdir(PROJECTS) else [])
              if os.path.exists(os.path.join(PROJECTS, d, "project.yml"))
              and os.path.normcase(os.path.abspath(os.path.join(PROJECTS, d))) not in seen]
    # projects added from anywhere (the project browser's Add)
    for p in cfg.get("projects_added", []):
        key = os.path.normcase(os.path.abspath(p))
        if os.path.exists(os.path.join(p, "project.yml")) and key not in seen and \
                key not in {os.path.normcase(os.path.abspath(o)) for o in others}:
            others.append(p)
    others.sort(key=lambda p: os.path.getmtime(os.path.join(p, "project.yml")), reverse=True)
    return out + others


def add_project(path):
    """A project from anywhere into the project browser's list (its folder, or its project.yml) -> its folder, or
    None when it is not a project."""
    folder = os.path.dirname(path) if os.path.basename(path).lower() == "project.yml" else path
    if not os.path.exists(os.path.join(folder, "project.yml")):
        return None
    folder = os.path.abspath(folder)
    cfg = config.load()
    added = [p for p in cfg.get("projects_added", []) if os.path.normcase(p) != os.path.normcase(folder)]
    cfg["projects_added"] = [folder] + added
    config.save(cfg)
    return folder


def remember(path):
    if is_example(path):
        return                                  # (an example is listed as one; its copy is what was opened)
    cfg = config.load()
    cfg["recent"] = [path] + [p for p in cfg.get("recent", []) if p != path][:9]
    config.save(cfg)


def decal_template(qid, texture, size):
    """Where a decal object's entity lands in the quest's DLC (the object's template)."""
    from .furniture import decal_name
    return "\\".join(["dlc", f"dlc{qid}", "data", "entities", decal_name(texture, size) + ".w2ent"])


def ascii_id(text, sep="_", lower=True):
    """The one way an id is made from typed text (a project, an item, an object, a place, a fact): a-z, 0-9 and
    `sep` between the words. The game's tools take nothing else (07.10.: "mehrscheiß" as a project, "stück scheiße"
    as an item and "größe erreicht" as a fact stopped radish: "must contain only following characters: [a-z_0-9]").
    lower=False keeps capitals (a fact: the game's own have them)."""
    import unicodedata
    low = str(text or "")
    low = low.lower() if lower else low
    for a, b in (("ß", "ss"), ("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue"),
                 ("ẞ", "SS")):
        low = low.replace(a, b)
    low = unicodedata.normalize("NFKD", low).encode("ascii", "ignore").decode()
    return sep.join("".join(c if c.isalnum() else " " for c in low).split())


def is_id(text):
    """Is it an id the game's tools take (a-z, 0-9, _)?"""
    return bool(text) and all(c in "abcdefghijklmnopqrstuvwxyz0123456789_" for c in str(text))


def fact_id(text):
    """A fact's name as radish takes it (a-z, A-Z, 0-9, _), from what was typed: "größe erreicht" ->
    groesse_erreicht. One that is fine stays as it is."""
    text = str(text or "").strip()
    return text if is_fact(text) else ascii_id(text, lower=False)


def is_fact(text):
    return bool(text) and all(c.isascii() and (c.isalnum() or c == "_") for c in str(text))


def slug_of(name):
    """The folder and id of a project from its name: letters and digits, ASCII only."""
    return ascii_id(name, "")[:24] or "project"


def free_folder(slug, keep=None):
    """Documents\\Conjunction\\<slug> - or <slug>2, 3 ... when taken (`keep`: the project's own folder counts as free)."""
    path, n = os.path.join(PROJECTS, slug), 2
    while os.path.exists(path) and not (keep and os.path.normcase(path) == os.path.normcase(keep)):
        path, n = os.path.join(PROJECTS, f"{slug}{n}"), n + 1
    return path


def last_or_new():
    """The project the editor opens at its start: the one worked on last, or a new one when there is none."""
    for p in recent():
        return p
    return new_project("Untitled")


def own_copy(path):
    """An example is opened as the user's own copy (Documents\\Conjunction\\<name>): editing it must not change Conjunction's
    examples. An existing copy is opened again."""
    if not is_example(path):
        return path
    copy = os.path.join(PROJECTS, os.path.basename(path))
    if not os.path.exists(os.path.join(copy, "project.yml")):
        shutil.copytree(path, copy, ignore=shutil.ignore_patterns("build", VERSIONS, "wcc.log"), dirs_exist_ok=True)
        Project(copy).signed()
    return copy


VERSIONS = "versions"           # <project>/versions/<quest id of a run>/{dlc, mod, project}: Build & Play's runs
KEEP_VERSIONS = 5


def snapshot(project_path, qid):
    """The project's files as this run was built (to go back to it later) -> versions/<qid>/project."""
    dst = os.path.join(project_path, VERSIONS, qid, "project")
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(project_path, dst, ignore=shutil.ignore_patterns("build", VERSIONS, "wcc.log", "__pycache__"))
    prune_versions(project_path)


def park_run(project_path, root, name, part):
    """A run's DLC (part "dlc") or mod bundle ("mod") out of the game folder into versions/<its quest id>/<part>."""
    qid = name[3:] if part == "dlc" else name[6:]                   # dlc<qid> / moddlc<qid>
    dst = os.path.join(project_path, VERSIONS, qid, part)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.move(os.path.join(root, name), dst)


def prune_versions(project_path):
    """Only the newest KEEP_VERSIONS runs stay."""
    d = os.path.join(project_path, VERSIONS)
    import re

    def number(path):                           # (by the run's number: a run parked just now is not the newest)
        m = re.search(r"r(\d+)$", os.path.basename(path))
        return int(m.group(1)) if m else -1
    runs = sorted((os.path.join(d, n) for n in os.listdir(d) if os.path.isdir(os.path.join(d, n))),
                  key=number, reverse=True) if os.path.isdir(d) else []
    for old in runs[KEEP_VERSIONS:]:
        shutil.rmtree(old, ignore_errors=True)


def drop_old_runs(project):
    """The DLCs (and mod bundles) of the project's older Build & Play runs out of the game folder, parked in its
    versions - only while the game is closed (a running game holds them). Each run is a quest of its own to the
    game: left in, every one of them puts its people into the world. -> the folders taken out"""
    import re
    game = config.load().get("game") or ""
    base = re.escape(project.base_id)
    gone = []
    for folder, prefix in (("dlc", "dlc"), ("Mods", "moddlc")):
        root = os.path.join(game, folder)
        for d in os.listdir(root) if os.path.isdir(root) else []:
            if re.fullmatch(rf"{prefix}{base}r\d+", d.lower()) and d.lower() != prefix + project.id:
                try:
                    park_run(project.path, root, d, "dlc" if folder == "dlc" else "mod")
                    gone.append(d)
                except OSError as e:
                    print(f"[project] {d} could not go: {e}", flush=True)
    prune_versions(project.path)
    return gone


def examples():
    """Conjunction's example projects: [(name, path)]."""
    d = os.path.join(os.path.dirname(HERE), "examples")
    out = []
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        p = os.path.join(d, name)
        if os.path.exists(os.path.join(p, "project.yml")):
            out.append((Project(p).meta.get("name") or name, p))
    return out


def rename(project, name):
    """A new name. Never built yet: its id and its folder follow the name (Maxim 04.10.: a typo in the name stayed
    in the id); once built they stay - the game knows the quest by its id, a new one would leave the old DLC in it.
    -> the project's path (moved or not)."""
    name = " ".join(name.split())
    if not name or name == project.meta.get("name"):
        return project.path
    old = project.meta.get("name")
    project.meta["name"] = name
    quest = project.meta.get("quest")
    if isinstance(quest, dict) and quest.get("title") in (None, "", old):
        quest["title"] = name                       # the journal's title went with the name: it still does
    built = os.path.isdir(os.path.join(project.path, "build"))
    inside = os.path.normcase(os.path.dirname(project.path)) == os.path.normcase(PROJECTS)
    if not built and inside:
        target = free_folder(slug_of(name), keep=project.path)
        tail = str(project.meta["id"])[-4:]
        project.meta["id"] = f"{os.path.basename(target)}{tail}"
        if os.path.normcase(target) != os.path.normcase(project.path):
            os.rename(project.path, target)
            cfg = config.load()
            cfg["recent"] = [target if os.path.normcase(p) == os.path.normcase(project.path) else p
                             for p in cfg.get("recent", [])]
            config.save(cfg)
            project.path = target
    project.save_meta()
    return project.path


def new_project(name, kind="quest"):
    """A new, empty project named `name` in Documents\\Conjunction (its folder from the name) -> its path.
    kind: quest, or place (a place mod - Maxim 06.10.: "ein neues Haus für Geralt ist eine extra Mod, keine Quest")."""
    path = free_folder(slug_of(name))
    # its id: the folder's name and a random tail - two people's "Bandit Camp" are two quests in the library
    # (the id names its DLC, facts, tags and its range of text ids)
    import uuid
    Project.create(path, f"{os.path.basename(path)}{uuid.uuid4().hex[:4]}", name, kind=kind)
    return path


def worlds():
    """radish world id per depot path (levels\\novigrad\\novigrad.w2w -> novigrad)."""
    repo = yaml.safe_load(open(os.path.join(config.load()["radish"], "repo.quests", "worlds.repo.yml"),
                               encoding="utf-8"))
    return {v["world"].replace("/", "\\").lower(): k for k, v in repo["repository"]["worlds"].items()}


def world_paths():
    """depot path per radish world id (velen and novigrad: both levels\\novigrad\\novigrad.w2w)."""
    repo = yaml.safe_load(open(os.path.join(config.load()["radish"], "repo.quests", "worlds.repo.yml"),
                               encoding="utf-8"))
    return {k: v["world"].replace("/", "\\").lower() for k, v in repo["repository"]["worlds"].items()}


# the libraries Conjunction builds, as they were named before 05.10. (w3suite) and now: a project from then names the
# old DLC, which the game no longer has (06.10.: "Not found in the game: dlc\\dlcw3suitemeshes\\...")
RENAMED_DLCS = {"dlc\\dlcw3suitemeshes\\": "dlc\\dlcconjunctionmeshes\\",
                "dlc\\dlcw3suitefoliage\\": "dlc\\dlcconjunctionfoliage\\"}


def _renamed(template):
    low = template.lower()
    for old, new in RENAMED_DLCS.items():
        if low.startswith(old):
            return new + template[len(old):]
    return template


class Project:
    def __init__(self, path):
        self.path = os.path.abspath(path)
        self.meta = yaml.safe_load(open(os.path.join(self.path, "project.yml"), encoding="utf-8"))
        self.places = {}
        for f in sorted(glob.glob(os.path.join(self.path, "places", "*.yml"))):
            name = os.path.splitext(os.path.basename(f))[0]
            self.places[name] = yaml.safe_load(open(f, encoding="utf-8")) or {}
            changed = False
            for o in self.places[name].get("objects") or []:
                t = o.get("template") if isinstance(o, dict) else None
                if isinstance(t, str) and _renamed(t) != t:
                    o["template"], changed = _renamed(t), True
            if changed:                                 # (said once, kept: the place names the new library)
                print(f"[project] {name}: objects of the renamed libraries now from dlcconjunction...", flush=True)
                self.save_place(name)
            elif self._people_named(name, built=True):  # (a person placed before 07.10. without an id)
                self.save_place(name)
        self._ascii_ids()

    def _ascii_ids(self):
        """Every id of the project as the game's tools take it (is_id): an item, an object or a place named with an
        umlaut or a space before 07.10. gets its ascii_id, and every reference to it follows (own:<item>,
        <place>/<object>). Once, kept."""
        items = (self.meta.get("quest") or {}).get("items") or {}
        refs, place_names = {}, {}
        for iid in list(items):
            if not is_id(iid):
                new = base = ascii_id(iid, "")[:20] or "item"
                n = 2
                while new in items:
                    new, n = f"{base}{n}", n + 1
                items[new] = items.pop(iid)
                refs[f"own:{iid}"] = f"own:{new}"
        for name in list(self.places):
            if not is_id(name):
                new = base = ascii_id(name) or "place"
                n = 2
                while new in self.places:
                    new, n = f"{base}_{n}", n + 1
                place_names[name] = new
        for name, p in self.places.items():
            objs = p.get("objects") or []
            taken = {o.get("id") for o in objs if isinstance(o, dict)}
            for o in objs:
                oid = o.get("id") if isinstance(o, dict) else None
                if oid and not is_id(oid):
                    new = base = ascii_id(oid) or "object"
                    n = 2
                    while new in taken:
                        new, n = f"{base}_{n}", n + 1
                    taken.add(new)
                    o["id"] = new
                    refs[f"{name}/{oid}"] = f"{place_names.get(name, name)}/{new}"
            for o in objs:                          # (the place renamed: its objects' references follow)
                if name in place_names and isinstance(o, dict) and o.get("id"):
                    refs.setdefault(f"{name}/{o['id']}", f"{place_names[name]}/{o['id']}")
        facts = {}

        def find_facts(x, key=None):                # a fact's name: under "fact", or a Set fact's "name"
            if isinstance(x, dict):
                for k, v in x.items():
                    if isinstance(v, str) and (k == "fact" or (k == "name" and key == "fact")) and v \
                            and not is_fact(v):
                        facts[v] = fact_id(v)
                    find_facts(v, k)
            elif isinstance(x, list):
                for v in x:
                    find_facts(v, key)
        find_facts(self.meta.get("quest"))
        if not refs and not place_names and not facts:
            return

        def follow(x, key=None):
            if isinstance(x, dict):
                return {k: (facts.get(v, v) if isinstance(v, str) and (k == "fact" or (k == "name" and key == "fact"))
                            else follow(v, k)) for k, v in x.items()}
            if isinstance(x, list):
                return [follow(v, key) for v in x]
            if isinstance(x, str):
                if x in refs:
                    return refs[x]
                if x in place_names:            # (a place named by itself: Show place, a step's world part)
                    return place_names[x]
            return x
        self.meta = follow(self.meta)
        for name in list(self.places):
            self.places[name] = follow(self.places[name])
            new = place_names.get(name)
            if new:
                self.places[new] = self.places.pop(name)
                os.remove(os.path.join(self.path, "places", f"{name}.yml"))
            self.save_place(new or name)
        self.save_meta()
        print(f"[project] ids made readable for the game's tools: "
              f"{', '.join(f'{a} -> {b}' for a, b in list(refs.items()) + list(place_names.items()) + list(facts.items()))}", flush=True)

    @staticmethod
    def create(path, pid, name, description="", kind="quest"):
        """kind: quest (steps, talks, a journal entry) or place (a place mod: its places always in the world)."""
        os.makedirs(os.path.join(path, "places"), exist_ok=True)
        meta = {"id": pid, "name": name, "description": description}
        if kind == "place":
            meta["kind"] = "place"
        yaml.safe_dump(meta, open(os.path.join(path, "project.yml"), "w", encoding="utf-8"), sort_keys=False)
        p = Project(path)
        p.signed()
        return p

    def signed(self):
        """The maker's mark and the history's first step (marks.py, provenance.py) - for a project that has none
        yet; never in the way of the work."""
        try:
            from . import marks, provenance
            marks.ensure(self)
            provenance.note_safely(self.path, "edit")
        except Exception as ex:                         # noqa: BLE001
            print(f"[project] mark / history: {ex}")

    @property
    def id(self):
        """The quest's id in the game: the project's id, and the run of Build & Play (<id>r<n>) - each run a new quest
        to the game, so it starts fresh (02.10.); an export has no run."""
        run = int(self.meta.get("run") or 0)
        return f"{self.base_id}r{run}" if run else self.base_id

    @property
    def base_id(self):
        """The project's own id (what players' installs and updates know it by)."""
        return str(self.meta["id"]).lower()

    def place(self, name, world=None):
        p = self.places.setdefault(name, {"world": world, "visible": "start", "objects": []})
        if world and not p.get("world"):
            p["world"] = world
        return p

    @staticmethod
    def _slug(text):
        return ascii_id(text)

    def _template_id(self, o):
        """The id an object gets from its template's file name (novigrad_rich_woman)."""
        return self._slug(os.path.splitext(os.path.basename(o["template"].replace("\\", "/")))[0])

    def _people_named(self, name, built=False):
        """Every person of a place has an id of its own, kept in the place file (07.10.: the build named a person
        without one npc<k> only for itself - the editor could not hide that built person while its copy stood there:
        two of them, one in the other). A person placed now: from its template (as name_object); `built`: a place
        loaded from before - the build's name (npc<k>, k its place in the list), so a quest built then keeps its
        people. -> whether one was named"""
        try:
            from .quest import is_actor
        except Exception:                               # noqa: BLE001 - (the quest module is not there: tools)
            return False
        objs = self.places.get(name, {}).get("objects") or []
        taken = {o.get("id") for o in objs if isinstance(o, dict)}
        changed = False
        for k, o in enumerate(objs):
            if not isinstance(o, dict) or o.get("id") or not o.get("template"):
                continue
            try:
                person = is_actor(o)
            except Exception:                           # noqa: BLE001 - a template the catalog does not know
                continue
            if person:
                first = f"npc{k}" if built else self._template_id(o)
                oid, n = first, 2
                while oid in taken:
                    oid, n = f"{first}_{n}", n + 1
                o["id"] = oid
                taken.add(oid)
                changed = True
        return changed

    def save_place(self, name):
        self._people_named(name)
        yaml.safe_dump(self.places[name], open(os.path.join(self.path, "places", f"{name}.yml"), "w",
                                               encoding="utf-8"), sort_keys=False, default_flow_style=None)

    def save_meta(self):
        yaml.safe_dump(self.meta, open(os.path.join(self.path, "project.yml"), "w", encoding="utf-8"),
                       sort_keys=False, allow_unicode=True)

    def find_object(self, place, pos, tol=0.05, near=1.5):
        """Index of the object of `place` standing at `pos` (the editor knows objects by where they are) - or, none
        there, the nearest within `near` m (a creature settles after it was placed and is not where it was)."""
        objs = self.places.get(place, {}).get("objects", [])
        if not objs or pos is None:
            return None
        d = [sum((a - b) ** 2 for a, b in zip(o["pos"], pos)) for o in objs]
        i = min(range(len(objs)), key=d.__getitem__)
        return i if d[i] <= max(tol, near) ** 2 else None

    def name_object(self, place, index, name=None, base=None):
        """Give an object an id (for quest steps); without a name one is made from `base` (the catalog's title of
        it: 'blacksmith') or else its template's file name. Returns the id."""
        objs = self.places[place]["objects"]
        o = objs[index]
        if name is None:
            auto = self._template_id(o)
            made = o.get("id") in (auto,) or str(o.get("id") or "").startswith(auto + "_") and \
                str(o.get("id"))[len(auto) + 1:].isdigit()
            if o.get("id") and not (base and made):     # (an id made from the template gives way to a title)
                return o["id"]
            base = self._slug(base) if base else auto
            taken = {x.get("id") for x in objs if x is not o}
            name, n = base, 2
            while name in taken:
                name, n = f"{base}_{n}", n + 1
        old = o.get("id")
        o["id"] = name
        self.save_place(place)
        if old and old != name and self._rename_refs(f"{place}/{old}", f"{place}/{name}"):
            self.save_meta()                            # the quest's steps follow the new name
        return name

    def rename_object(self, place, index, name):
        """A name given on the quest tab (Maxim 08.10.: everything changeable there, and everywhere after it): a
        person's name above them in the game, and the object's id follows it - every step, dialogue and journal line
        of the quest with it. An empty name: the name above them goes, the id stays. -> the id."""
        name = (name or "").strip()
        objs = self.places[place]["objects"]
        o = objs[index]
        from . import quest
        if quest.is_actor(o):
            self.set_object(place, index, display=name or None)
        if not name:
            return o.get("id")
        base = self._slug(name)
        taken = {x.get("id") for x in objs if x is not o}
        new, n = base, 2
        while new in taken:
            new, n = f"{base}_{n}", n + 1
        return self.name_object(place, index, name=new)

    def _rename_refs(self, old, new):
        """Every `place/id` reference of the quest to `old` becomes `new`; returns whether one changed."""
        changed = False

        def fix(x):
            nonlocal changed
            if isinstance(x, dict):
                for k, v in x.items():
                    if v == old:
                        x[k] = new
                        changed = True
                    else:
                        fix(v)
            elif isinstance(x, list):
                for k, v in enumerate(x):
                    if v == old:
                        x[k] = new
                        changed = True
                    else:
                        fix(v)
        fix(self.meta.get("quest") or {})
        return changed

    def set_object(self, place, index, **fields):
        """Set (or with None remove) fields of an object - inventory, appearance, ... - and save the place."""
        o = self.places[place]["objects"][index]
        for k, v in fields.items():
            if v is None or v == [] or v == "":
                o.pop(k, None)
            else:
                o[k] = v
        self.save_place(place)
        return o

    def apply_change(self, line):
        """One editor report line: `change|placed|place=..|world=..|template=..|pos=x,y,z|rot=r,p,y`.
        Returns a short description or None if the line is not a change."""
        if "change|" not in line:
            return None
        parts = line.split("change|", 1)[1].strip().split("|")
        what, kv = parts[0], dict(p.split("=", 1) for p in parts[1:] if "=" in p)
        name = kv.get("place") or "default"
        world = worlds().get(kv.get("world", "").lower())
        pos = [round(float(v), 3) for v in kv["pos"].split(",")]
        place = self.place(name, world)
        if what == "placed":
            rot = [round(float(v), 2) for v in kv["rot"].split(",")]
            pos, rot = self._stamped(pos, rot)
            place["objects"].append({"template": kv["template"], "pos": pos, "rot": rot})
            if kv.get("appearance"):                    # the look it was placed with (a person picks one at random)
                place["objects"][-1]["appearance"] = kv["appearance"]
        elif what in ("removed", "effect", "effect_off", "look") or (
                what in ("moved", "rotated") and kv.get("game") == "1"):
            return self._world_change(what, kv, world, pos)
        elif what in ("deleted", "moved", "rotated"):
            # the object is found by where it was (moved: the drag's start, else its current position)
            key = [float(v) for v in kv["from"].split(",")] if what == "moved" else pos
            objs = place["objects"]
            if not objs:
                return None
            d = [sum((a - b) ** 2 for a, b in zip(o["pos"], key)) for o in objs]
            i = min(range(len(objs)), key=d.__getitem__)
            if d[i] > 0.05 ** 2:
                # none exactly there: the nearest of the same template within 1.5 m (a creature settles after it
                # was placed, so the game's position is not the stored one)
                same = [k for k, o in enumerate(objs) if o["template"].lower() == kv.get("template", "").lower()
                        and d[k] <= 1.5 ** 2]
                if not same:
                    return None
                i = min(same, key=d.__getitem__)
            if what == "deleted":
                objs.pop(i)
            else:
                objs[i]["pos"], objs[i]["rot"] = self._stamped(pos, [round(float(v), 2)
                                                                     for v in kv["rot"].split(",")])
        else:
            return None                                 # selected etc.: nothing to store
        self.save_place(name)
        return f"{what} in {name}: {kv.get('template') or ''} at {pos}"

    def _stamped(self, pos, rot):
        """The placing profile's mark in an object's last digits (marks.py: at most 0.1 mm, 0.01 degrees)."""
        try:
            from . import marks
            return marks.stamp(self, pos, rot)
        except Exception as ex:                         # noqa: BLE001 - placing never fails for the mark
            print(f"[project] mark: {ex}")
            return pos, rot

    def _world_change(self, what, kv, world, pos):
        """An object the game placed, changed in the editor: kept in world.yml (worldchanges.py), not in a place."""
        from . import worldchanges
        guid = kv.get("guid", "")
        if not worldchanges.guid_ok(guid):
            return None                             # made at run time (a crowd's NPC): nothing lasting to key on
        label = (worldchanges.short_name(kv.get("name") or kv.get("template"))
                 or f"object at {pos[0]:.0f}, {pos[1]:.0f}")
        if what == "effect_off":
            for c in worldchanges.load(self.path):
                if c["guid"] == guid and c["do"] == "effect":
                    worldchanges.drop(self.path, c["id"])
            return f"effect off: {label}"
        if what in ("moved", "rotated"):
            rot = [float(v) for v in kv.get("rot", "0,0,0").split(",")]
            # where it stood: the drag's start (a move keeps the rotation); home/homerot when the editor knows them
            home = [float(v) for v in (kv.get("home") or kv.get("from") or kv["pos"]).split(",")]
            home_rot = [float(v) for v in (kv.get("homerot") or kv.get("rot", "0,0,0")).split(",")]
            cid = worldchanges.add(self.path, guid, "move", value=worldchanges.transform(pos, rot), label=label,
                                   world=world, pos=pos, otherwise=worldchanges.transform(home, home_rot))
            return f"world change {cid} (move): {label}"
        do = {"removed": "remove", "effect": "effect", "look": "look"}[what]
        cid = worldchanges.add(self.path, guid, do, value=kv.get("value", ""), label=label, world=world, pos=pos)
        return f"world change {cid} ({do}{' ' + kv['value'] if kv.get('value') else ''}): {label}"

    test_from = None                        # ("main", index) / ("path", id, index): a test build starts there

    def generate(self, defdir, skip_templates=()):
        """radish quest definition into defdir: production, one layer per place, a structure that shows the places
        when the quest starts and then keeps running (a quest that ended would no longer hold its places)."""
        os.makedirs(defdir, exist_ok=True)
        for f in glob.glob(os.path.join(defdir, "*.yml")):
            os.remove(f)
        from .quest import idspace
        prod = {"production": {"settings": {
            "id": self.id, "caption": self.meta.get("name", self.id), "description": self.meta.get("description", ""),
            "menuvisibile": True, "enabled": True, "storesdata": False, "strings-idspace": idspace(self.id),
            "strings-idstart": 0, "version": 12}}}
        yaml.safe_dump(prod, open(os.path.join(defdir, f"prod.quest-{self.id}.yml"), "w", encoding="utf-8"),
                       sort_keys=False)
        from . import meshlib, plugins, quest
        from .bundles import Depot
        mesh_of = meshlib.reverse_index()
        from . import foliage
        tree_of = foliage.reverse_index()
        own_entities = {}
        self.extra_resources = {}               # {depot path in the quest's DLC: file} - a planted tree's collision
        # what this game version does not have (the remaster dropped some files) or REDkit cannot cook
        # (skip_templates) is left out with a note - one bad file makes the whole cooking fail
        depot = Depot()
        self.skipped = []

        def missing(template):
            if template == "cj_envhide":               # a hide area: the build makes its entity (envhide.py)
                return False
            if template.lower() in tree_of:            # a tree of the foliage library: the quest makes its own
                return False
            res = mesh_of.get(template.lower()) or template
            own = f"dlc\\dlc{self.id}\\".lower()        # made by the quest itself (a decal)
            return not res.lower().startswith(("dlc\\dlcconjunction", own)) and not depot.exists(res)

        kept_places = {}
        for name, p in self.places.items():
            objs = []
            for o in p.get("objects", []):
                if not quest.is_actor(o) and missing(o["template"]):
                    self.skipped.append(f"{name}/{o.get('id') or o['template']} (not in this version of the game)")
                elif o["template"].lower() in skip_templates:
                    self.skipped.append(f"{name}/{o.get('id') or o['template']} (REDkit cannot cook it)")
                else:
                    objs.append(o)
            kept_places[name] = dict(p, objects=objs)
        all_places, self.places = self.places, kept_places
        try:
            blocks, journals, meta, tags, communities, scenes, rewards, speech, items = quest.generate(
                self, plugins.get().blocks())
        finally:
            self.places = all_places

        # meshes from the local mesh library travel with the quest: their wrapper entities are built into its DLC
        # (people who install the quest do not have the library)
        decal_of = meshlib.decal_reverse_index()

        def own_mesh(template):
            tex = decal_of.get(template.lower())
            if tex:                                     # a decal picture of the library: its entity travels too
                from .furniture import decal_entity
                ename = meshlib.decal_entity_name(tex)
                own_entities[ename] = decal_entity(tex, (1.0, 1.0))
                return "\\".join(["dlc", f"dlc{self.id}", "data", "entities", ename + ".w2ent"])
            tree = tree_of.get(template.lower())
            if tree:                                    # a planted tree: drawn, and its collision as in the library
                ename = foliage.entity_name(tree)
                coll = foliage.quest_collision(self, tree, defdir)
                own_entities[ename] = foliage.entity(tree, coll)
                return "\\".join(["dlc", f"dlc{self.id}", "data", "entities", ename + ".w2ent"])
            mesh = mesh_of.get(template.lower())
            if not mesh:
                return template
            ename = meshlib.entity_name(mesh)
            own_entities[ename] = meshlib.wrapper(mesh)
            return "\\".join(["dlc", f"dlc{self.id}", "data", "entities", ename + ".w2ent"])

        layers = {}
        for name, p in kept_places.items():
            if not p.get("objects"):
                continue
            statics = {}
            for i, o in enumerate(p["objects"]):
                if quest.is_actor(o) or o.get("marker"):
                    continue                            # NPCs come as a community; spot markers stay in the editor
                if o.get("trail"):
                    # a trail: its pieces - in the layer of the clue step that shows it, else here, always there
                    if f"{name}/{o.get('id')}" in getattr(self, "step_trails", ()):
                        continue
                    for n, pc in enumerate(o.get("pieces") or []):
                        statics[f"{o.get('id') or f'obj{i:03d}'}_p{n:02d}"] = {
                            "template": pc[4], "pos": [float(v) for v in pc[:3]], "rot": [0.0, 0.0, float(pc[3])]}
                    continue
                if o.get("envhide"):
                    # an area where the game's terrain / foliage / water is not drawn (envhide.py): an entity of the
                    # quest's own with the engine's visibility component, in this place's layer
                    from .envhide import entity, entity_name
                    ename = entity_name(name, o.get("id") or f"obj{i:03d}")
                    own_entities[ename] = entity(o["envhide"])
                    o = dict(o, template="\\".join(["dlc", f"dlc{self.id}", "data", "entities", ename + ".w2ent"]))
                if o.get("decal"):
                    # a picture painted onto the world (a texture of the game or a pack): an entity of the quest's
                    # own with a decal component - projected down its Z, upright on a wall with pitch 90
                    from .furniture import decal_entity, decal_name
                    size = [float(v) for v in (o.get("size") or [1.0, 1.0])][:2]
                    own_entities[decal_name(o["decal"], size)] = decal_entity(str(o["decal"]), size)
                    o = dict(o, template=decal_template(self.id, o["decal"], size))
                s = {"template": own_mesh(o["template"]), "pos": o["pos"], "rot": o["rot"]}
                if (name, o.get("id")) in tags:
                    s["tags"] = [tags[(name, o["id"])]]
                statics[o.get("id") or f"obj{i:03d}"] = s
            if statics:
                layers[name] = {"world": p["world"], "statics": statics}
        for w, m in meta.items():
            layers[quest.meta_layer(self.id, w)] = dict({"world": w}, **m)
        layers.update(getattr(self, "step_layers", {}))            # clue entries' own layers (trails, examine points)
        own_entities.update(getattr(self, "step_entities", {}))
        # radish wants editable (production, structure) and other definitions in separate files
        yaml.safe_dump({"layers": layers}, open(os.path.join(defdir, "layers.yml"), "w", encoding="utf-8"),
                       sort_keys=False, default_flow_style=None)
        add_graph_objectives(self.path, journals)
        if journals:
            yaml.safe_dump({"journals": journals}, open(os.path.join(defdir, "journals.yml"), "w",
                                                         encoding="utf-8"), sort_keys=False, allow_unicode=True)
        if own_entities:
            yaml.safe_dump({"entities": own_entities}, open(os.path.join(defdir, "entities.yml"), "w",
                                                             encoding="utf-8"), sort_keys=False)
        if items:                                       # the quest's own letters and books (radish: <quest>_own_<id>)
            yaml.safe_dump({"items": {"own": items}}, open(os.path.join(defdir, "items.yml"), "w", encoding="utf-8"),
                           sort_keys=False, allow_unicode=True)
        if rewards:
            yaml.safe_dump({"rewards": rewards}, open(os.path.join(defdir, "rewards.yml"), "w", encoding="utf-8"),
                           sort_keys=False)
        if communities:
            yaml.safe_dump({"communities": communities}, open(os.path.join(defdir, "communities.yml"), "w",
                                                               encoding="utf-8"), sort_keys=False)
        scenedir = os.path.join(os.path.dirname(defdir), "definition.scenes")
        if os.path.isdir(scenedir):
            for f in glob.glob(os.path.join(scenedir, "*.yml")):
                os.remove(f)
        # a quest put into one of the game's quests: that phase, changed, to be built under the game's path
        gamedir = os.path.join(os.path.dirname(defdir), "definition.game")
        if os.path.isdir(gamedir):
            shutil.rmtree(gamedir)
        ig = (self.meta.get("quest") or {}).get("inside_game") or {}
        if ig.get("phase"):
            from . import graph_edit
            from .bundles import Depot
            from .cr2w import CR2W
            f = CR2W(Depot().read(ig["phase"]))
            graph_edit.insert_hook(f, int(ig["block"]), ig.get("socket"), *quest.inside_facts(self.id))
            target = os.path.join(gamedir, ig["phase"].replace("/", "\\"))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            open(target, "wb").write(f.save())
        # game cutscenes replaced: every game scene that plays one, with the other one in it (cutscene_swap.py)
        from . import cutscene_swap
        changes, files = {}, {}
        whole = {str(sw.get("scene", "")).lower() for sw in (self.meta.get("swaps") or {}).values()}
        for cs in self.meta.get("cutscene_swaps") or []:
            if not (cs.get("old") and cs.get("new")):
                continue
            for scene in cutscene_swap.info(cs["old"])["scenes"]:
                if scene.lower() in whole:
                    raise ValueError(f"{scene.rsplit(chr(92), 1)[-1]} is already replaced as a whole, its "
                                     f"cutscene cannot be replaced too")
                changes.setdefault(scene, {})[cs["old"]] = cs["new"]
            if cs.get("file"):                  # an own cutscene: into the mod bundle under its depot path
                files[cs["new"]] = cs["file"]
                target = os.path.join(gamedir, cs["new"])
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy(cs["file"], target)
        for scene, ch in sorted(changes.items()):
            data, hit = cutscene_swap.swapped(scene, ch, files)
            if not hit:
                continue
            target = os.path.join(gamedir, scene.replace("/", "\\"))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            open(target, "wb").write(data)
        targets = {name: scene.pop("_target") for name, scene in scenes.items() if scene.get("_target")}
        if targets:                             # swapped game scenes: built to the game's paths
            os.makedirs(scenedir, exist_ok=True)
            yaml.safe_dump(targets, open(os.path.join(scenedir, "targets.yml"), "w", encoding="utf-8"))
        for name, scene in scenes.items():
            os.makedirs(scenedir, exist_ok=True)
            yaml.safe_dump(scene, open(os.path.join(scenedir, f"scene.{name}.yml"), "w", encoding="utf-8"),
                           sort_keys=False, allow_unicode=True)
        # the names people are shown by (build: DLC strings conjunction_names.ws looks up by the person's tag)
        names_file = os.path.join(os.path.dirname(defdir), "definition.names.yml")
        if os.path.exists(names_file):
            os.remove(names_file)
        names = {f"{self.id}_{place}_{o['id']}": o["display"] for place, p in sorted(self.places.items())
                 for o in p.get("objects", []) if o.get("display") and o.get("id") and quest.is_actor(o)}
        if names:
            yaml.safe_dump(names, open(names_file, "w", encoding="utf-8"), sort_keys=True, allow_unicode=True)
        # gwent: stand-ins the build makes the game's minigame blocks (minigames.py)
        mg_file = os.path.join(os.path.dirname(defdir), "definition.minigames.yml")
        if os.path.exists(mg_file):
            os.remove(mg_file)
        if getattr(self, "minigames", None):
            yaml.safe_dump(self.minigames, open(mg_file, "w", encoding="utf-8"), sort_keys=True)
        # texts the game asks for by key (notices): beside the definition, the build adds them to the strings
        keyed_file = os.path.join(os.path.dirname(defdir), "definition.strings.csv")
        if os.path.exists(keyed_file):
            os.remove(keyed_file)
        if getattr(self, "keyed_strings", None):
            rows = [f"{sid}|        |{key}|{' '.join(str(text).split())}" for sid, key, text in self.keyed_strings]
            open(keyed_file, "w", encoding="utf-8", newline="\n").write("\n".join(rows) + "\n")
        # own recordings: the build makes the DLC's speech file of them (speech.py)
        speech_file = os.path.join(os.path.dirname(defdir), "definition.speech.yml")
        if os.path.exists(speech_file):
            os.remove(speech_file)
        if speech:
            yaml.safe_dump({"speech": speech}, open(speech_file, "w", encoding="utf-8"), sort_keys=False,
                           allow_unicode=True)
        yaml.safe_dump({"structure": {"quest": {"blocks": blocks}}},
                       open(os.path.join(defdir, "structure.root.yml"), "w", encoding="utf-8"), sort_keys=False,
                       default_flow_style=None, allow_unicode=True)
        return defdir

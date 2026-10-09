"""Plug-ins: a folder with `plugin.py` (`register(api)`) and `plugin.json` (read without running any code). Found in
`<repo>/plugins/`, `%APPDATA%\\Conjunction\\plugins\\` and the folders added in Settings > Plug-ins (a plug-in's own
repo works in place). Maxim 05.10.: Conjunction is an app first; plug-ins extend each other and get their own place
in Settings.

    plugin.json   {"id": "motion", "name": "Motion", "version": "0.1", "api": 1, "requires": [], "adult": false,
                   "author": "...", "description": "..."}

    def register(api):
        motion = api.require("motion")          # what another plug-in provided (it loads first)
        api.provide(my_hooks)                   # what this one offers the others
        api.add_page("Animations", lambda app: Widget())        # a page of the app (works without the game)
        api.add_panel("Scenes", lambda editor: Widget())        # a tab of the in-game side panel
        api.add_inspector_section("npc", lambda editor, obj, place, index: Widget(), title="Animation")
        api.add_settings("Motion", [{"key": "fps", "label": "Frames per second", "type": "int", "default": 30}])
        api.settings()["fps"]                   # its own values (Settings > Motion)
        api.app_setting("tools.blender")        # Conjunction's (the Blender path, the game folder ...)
        api.add_catalog([{...}])                # entries; "kind" and "snap" travel with them
        api.add_block("play_scene", PlayScene())               # a quest step type (quest.py)
        api.add_scripts("scripts", runtime=True)               # WitcherScript: runtime (everyone) or editor mod
        api.add_uncooked_step(fn)               # fn(project, uncooked_dlc_dir, dlc, log): before cooking
        api.add_csv_rows(fn)                    # fn(project) -> {path in the DLC: (header, [rows])}, merged per DLC
        api.add_build_step(fn)                  # fn(project, out, log): after cooking, before packing
        api.add_link_handler("blend", fn)       # conjunction:blend?path=... (links.py: files below Documents\\Conjunction)
        api.run_job("Convert pack", fn, on_done)   # fn(progress) in a thread; progress(fraction, text) shown in the app

On / off per plug-in in Settings > Plug-ins (remembered). One marked adult is off until switched on there, never by
itself, and while off nothing of it is loaded or shown but its name. A plug-in whose `requires` are not there is
"needs <name>"; one that fails is "failed: <first line>" - none of them takes Conjunction down.
"""
import importlib.util
import json
import os
import traceback

from . import config

API = 1
HERE = os.path.dirname(os.path.abspath(__file__))
DIRS = [os.path.join(os.path.dirname(HERE), "plugins")]   # the ones Conjunction brings; and paths.PLUGINS


def manifest(folder):
    """A plug-in's plugin.json (or what its folder says: an older plug-in without one). -> dict with id, name ..."""
    m = {}
    path = os.path.join(folder, "plugin.json")
    if os.path.exists(path):
        try:
            m = json.load(open(path, encoding="utf-8")) or {}
        except (OSError, ValueError):
            m = {}
    name = os.path.basename(folder.rstrip("\\/"))
    m.setdefault("id", name.lstrip("_").lower().replace(" ", "_"))
    m.setdefault("name", m["id"].replace("_", " ").title())
    m.setdefault("version", "")
    m.setdefault("api", API)
    m.setdefault("requires", [])
    m["adult"] = bool(m.get("adult"))
    return m


class Missing(Exception):
    """api.require() of a plug-in that is not loaded."""


class Api:
    """What one plug-in registered."""

    def __init__(self, folder, meta=None, provided=None):
        self.folder = folder
        self.meta = dict(meta or {"name": os.path.basename(folder)})
        self._provided = provided if provided is not None else {}
        self.catalog, self.blocks, self.panels, self.scripts, self.build_steps = [], {}, [], [], []
        self.runtime_scripts, self.pages, self.inspector, self.settings_sections = [], [], [], []
        self.uncooked_steps, self.csv_rows, self.links = [], [], {}
        self.provides = None

    # --- who it is, what it gives and takes
    @property
    def id(self):
        return self.meta.get("id") or os.path.basename(self.folder)

    def info(self, **meta):
        self.meta.update(meta)

    def require(self, plugin_id):
        """What plug-in `plugin_id` provided (it is loaded before this one when listed in `requires`)."""
        if plugin_id not in self._provided:
            raise Missing(plugin_id)
        return self._provided[plugin_id]

    def provide(self, obj):
        self.provides = obj
        self._provided[self.id] = obj

    # --- places in Conjunction
    def add_catalog(self, entries):
        self.catalog.append(list(entries))

    def add_block(self, name, cls):
        self.blocks[name] = cls

    def add_panel(self, title, factory):
        self.panels.append((title, factory))

    def add_page(self, title, factory):
        """A page of the app (no game needed): factory(app) -> QWidget."""
        self.pages.append((title, factory))

    def add_inspector_section(self, kind, factory, title=None):
        """A section of the in-game inspector for a selected thing: kind npc | object | container | any (or a
        function obj -> bool); factory(editor, obj, place, index) -> QWidget."""
        self.inspector.append((kind, factory, title or self.meta.get("name") or self.id))

    def add_settings(self, title, schema_or_factory):
        """Its section of Settings: a list of fields ({key, label, type: text | path | file | int | float | bool |
        choice, default, choices}) or factory(values) -> QWidget (values: settings())."""
        self.settings_sections.append((title, schema_or_factory))

    def settings(self):
        """Its own values (Settings > its section), saved with Conjunction's config."""
        from .settings import plugin_values
        return plugin_values(self.id, self.settings_sections)

    @staticmethod
    def app_setting(key, default=None):
        """One of Conjunction's settings: general.*, game.*, tools.blender ..."""
        from .settings import value
        return value(key, default)

    # --- the game and the build
    def add_scripts(self, subdir, runtime=False):
        """WitcherScript files installed with Conjunction's mod: runtime (every player's) or the editor's."""
        (self.runtime_scripts if runtime else self.scripts).append(os.path.join(self.folder, subdir))

    def add_build_step(self, fn):
        self.build_steps.append(fn)

    def add_uncooked_step(self, fn):
        """fn(project, uncooked_dlc_dir, dlc, log) after the quest is encoded, before cooking: what it writes under
        the DLC's folder is cooked with it (own .w2anims, cutscenes)."""
        self.uncooked_steps.append(fn)

    def add_csv_rows(self, fn):
        self.csv_rows.append(fn)

    # --- the app
    def add_link_handler(self, action, fn):
        """conjunction:<action>?<query> (links.py) -> fn(params)."""
        self.links[action] = fn

    @staticmethod
    def run_job(name, fn, on_done=None):
        from . import jobs
        return jobs.run(name, fn, on_done)


class Plugins:
    def __init__(self, dirs=None, enabled=None):
        """dirs: where to look (default: DIRS + Settings' folders); enabled: {id: bool} (default: Settings')."""
        from . import settings
        self.loaded, self.failed, self.found = [], [], []
        self.status = {}                                # id -> loaded | off | needs X | failed: ...
        self._provided = {}
        from .paths import PLUGINS
        dirs = list(dirs) if dirs is not None else DIRS + [PLUGINS]     # (06.10.: no folders from anywhere)
        enabled = settings.plugins_enabled() if enabled is None else enabled
        cands = {}
        for d in dirs:
            if not os.path.isdir(d):
                continue
            # a folder that is itself a plug-in (a repo added in Settings), or one that holds plug-ins
            itself = os.path.isfile(os.path.join(d, "plugin.py"))
            subs = [d] if itself else [os.path.join(d, n) for n in sorted(os.listdir(d))]
            for folder in subs:
                name = os.path.basename(folder)
                if not os.path.isfile(os.path.join(folder, "plugin.py")) or name.startswith("."):
                    continue
                if name.startswith("_") and not itself:
                    continue                            # "_name": an example or a draft - only when added itself
                m = manifest(folder)
                if m["id"] in cands:
                    continue                            # (the first found wins: the repo's before the user's)
                cands[m["id"]] = (folder, m)
                self.found.append((folder, m))
        on = {}
        for pid, (_folder, m) in cands.items():
            want = enabled.get(pid)
            on[pid] = bool(want) if want is not None else not m["adult"]     # adult: off until switched on
            if not on[pid]:
                self.status[pid] = "off"
        # the order: every plug-in after those it requires
        done, order = set(), []

        def visit(pid, path=()):
            if pid in done or pid in path:
                return
            for r in cands[pid][1]["requires"]:
                if r in cands:
                    visit(r, path + (pid,))
            done.add(pid)
            order.append(pid)
        for pid in sorted(cands):
            visit(pid)
        for pid in order:
            if not on[pid]:
                continue
            folder, m = cands[pid]
            lacking = [r for r in m["requires"] if self.status.get(r) != "loaded"]
            if lacking:
                names = [cands[r][1]["name"] if r in cands else r for r in lacking]
                self.status[pid] = "needs " + ", ".join(names)
                continue
            if int(m.get("api") or API) > API:
                self.status[pid] = f"needs a newer Conjunction (plug-in API {m['api']})"
                continue
            try:
                spec = importlib.util.spec_from_file_location(f"conjunction_plugin_{pid}", os.path.join(folder,
                                                                                                      "plugin.py"))
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                api = Api(folder, m, self._provided)
                mod.register(api)
                self.loaded.append(api)
                self.status[pid] = "loaded"
            except Missing as ex:
                self.status[pid] = f"needs {ex.args[0]}"
            except Exception:                           # noqa: BLE001 - a broken plug-in is skipped, not fatal
                tb = traceback.format_exc(limit=3)
                self.failed.append((folder, tb))
                last = [ln for ln in tb.strip().splitlines() if ln.strip()][-1]
                self.status[pid] = f"failed: {last}"

    def listing(self):
        """[(manifest, status)] of every plug-in found - an adult one off: only its name, nothing of it loaded."""
        out = []
        for _folder, m in self.found:
            st = self.status.get(m["id"], "off")
            if m["adult"] and st == "off":
                m = {k: m[k] for k in ("id", "name", "adult")}
            else:                                       # its README, read in Settings > Plug-ins
                readme = next((os.path.join(_folder, n) for n in ("README.md", "readme.md", "README.txt")
                               if os.path.isfile(os.path.join(_folder, n))), None)
                if readme:
                    m = dict(m, readme=readme)
            out.append((m, st))
        return out

    def catalog_sources(self):
        return [entries for p in self.loaded for entries in p.catalog]

    def blocks(self):
        out = {}
        for p in self.loaded:
            out.update(p.blocks)
        return out

    def panels(self):
        return [t for p in self.loaded for t in p.panels]

    def pages(self):
        return [t for p in self.loaded for t in p.pages]

    def scripts(self, runtime=False):
        return [s for p in self.loaded for s in (p.runtime_scripts if runtime else p.scripts)]

    def build_steps(self):
        return [s for p in self.loaded for s in p.build_steps]

    def uncooked_steps(self):
        return [s for p in self.loaded for s in p.uncooked_steps]

    def csv_rows(self):
        return [s for p in self.loaded for s in p.csv_rows]

    def inspector_sections(self, kind, obj=None):
        """[(title, factory)] for a selected thing of this kind (npc | object | container)."""
        out = []
        for p in self.loaded:
            for k, factory, title in p.inspector:
                if (callable(k) and obj is not None and k(obj)) or k in (kind, "any"):
                    out.append((title, factory))
        return out

    def settings_sections(self):
        """[(plug-in id, title, schema or factory)] of the loaded plug-ins."""
        return [(p.id, t, s) for p in self.loaded for t, s in p.settings_sections]

    def link_handler(self, action):
        for p in self.loaded:
            if action in p.links:
                return p.links[action]
        return None


_instance = None


def get():
    global _instance
    if _instance is None:
        _instance = Plugins()
    return _instance


def reload():
    """After Settings > Plug-ins changed (the app; the game's editor takes it at its next start)."""
    global _instance
    _instance = None
    return get()

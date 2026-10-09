"""Where Conjunction keeps its things: one folder, Documents\\Conjunction (Maxim 06.10.: "es landet nie random auf dem
PC irgendwo, sondern immer im Conjunction-Ordner mit klarer Ordnerstruktur").

    Documents\\Conjunction\\
        projects\\       the projects
        quests\\         quest files to play (the library installs what lies here)
        exports\\        quests exported as .w3q
        bug-reports\\    reports saved by Report a bug
        plugins\\        one folder per plug-in (a plug-in kept elsewhere: a junction to it)
        tools\\          radish modding tools, unpacked from the release
        data\\           settings (config.json) and Conjunction's caches

CJ_HOME (a folder) puts all of it elsewhere - tests and the release's self test.

    migrate()          once: what an older Conjunction kept elsewhere moves in (config and caches from AppData,
                       projects from Documents\\Conjunction itself, plug-in folders added in Settings as junctions)
"""
import json
import os
import shutil
import subprocess

HOME = os.environ.get("CJ_HOME") or os.path.join(os.path.expanduser("~"), "Documents", "Conjunction")
PROJECTS = os.path.join(HOME, "projects")
QUESTS = os.path.join(HOME, "quests")
EXPORTS = os.path.join(HOME, "exports")
BUG_REPORTS = os.path.join(HOME, "bug-reports")
PLUGINS = os.path.join(HOME, "plugins")
TOOLS = os.path.join(HOME, "tools")
SCREENSHOTS = os.path.join(HOME, "screenshots")
IDENTITY = os.path.join(HOME, "identity")       # profile keys (identity.py) - the user keeps these files
DATA = os.path.join(HOME, "data")
OLD_DATA = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "conjunction")


def junction(link, target):
    """A directory junction (no admin rights needed) - a plug-in kept elsewhere shows in plugins\\."""
    if os.path.exists(link):
        return False
    os.makedirs(os.path.dirname(link), exist_ok=True)
    subprocess.run(["cmd", "/c", "mklink", "/J", link, target], capture_output=True, creationflags=0x08000000)
    return os.path.isdir(link)


def migrate(log=print):
    """Once, before the config is read: an older Conjunction's things into the one folder. Nothing is deleted;
    what is moved keeps its name. -> what was moved."""
    done = []
    os.makedirs(DATA, exist_ok=True)
    new_cfg = os.path.join(DATA, "config.json")
    if not os.path.exists(new_cfg) and os.path.isfile(os.path.join(OLD_DATA, "config.json")) and \
            os.path.normcase(OLD_DATA) != os.path.normcase(DATA):
        for name in os.listdir(OLD_DATA):
            src, dst = os.path.join(OLD_DATA, name), os.path.join(DATA, name)
            if not os.path.exists(dst):
                try:
                    shutil.move(src, dst)
                    done.append(name)
                except OSError as ex:                   # (a file in use: it stays where it was)
                    log(f"[paths] {name} stays in {OLD_DATA}: {ex}")
        log(f"[paths] settings and caches moved to {DATA} ({len(done)} items)")
    # projects that lay in Documents\Conjunction itself
    if os.path.isdir(HOME):
        moved = {}
        for name in sorted(os.listdir(HOME)):
            src = os.path.join(HOME, name)
            if name.startswith("_") or not os.path.isfile(os.path.join(src, "project.yml")):
                continue
            dst = os.path.join(PROJECTS, name)
            if os.path.exists(dst):
                continue
            os.makedirs(PROJECTS, exist_ok=True)
            try:
                shutil.move(src, dst)
                moved[os.path.normcase(src)] = dst
            except OSError as ex:
                log(f"[paths] project {name} stays where it is: {ex}")
        if moved and os.path.exists(new_cfg):
            cfg = json.load(open(new_cfg, encoding="utf-8"))
            cfg["recent"] = [moved.get(os.path.normcase(p), p) for p in cfg.get("recent") or []]
            json.dump(cfg, open(new_cfg, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
            log(f"[paths] {len(moved)} projects moved to {PROJECTS}")
        done += list(moved.values())
    # plug-in folders added in Settings: junctions in plugins\ (the folder setting goes)
    if os.path.exists(new_cfg):
        cfg = json.load(open(new_cfg, encoding="utf-8"))
        dirs = (cfg.get("plugins") or {}).get("dirs") or []
        if dirs:
            for d in dirs:
                if os.path.isfile(os.path.join(d, "plugin.py")):
                    name = os.path.basename(d.rstrip("\\/")).replace("conjunction-", "")
                    if junction(os.path.join(PLUGINS, name), d):
                        done.append(f"plugins\\{name} -> {d}")
            cfg["plugins"]["dirs"] = []
            json.dump(cfg, open(new_cfg, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    for d in (PROJECTS, QUESTS, EXPORTS, BUG_REPORTS, PLUGINS, TOOLS, IDENTITY):
        os.makedirs(d, exist_ok=True)
    return done

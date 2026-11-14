"""Conjunction in the game (MaximdeWinter 06.11.: the in-game version is the release, no .exe): one zip to unpack into the
game folder, as every mod.

    python tools/release/make_ingame_release.py [--version 0.1.0] [--out DIR]
        -> DIR/Conjunction-<version>.zip (+ .sha256, VirusTotal's report beside it)

The zip's folders are the game's:
    bin/x64_dx12/tw3se/mods/conjunction    the editor (Lua), the quests' runtime scripts, sounds
    bin/x64_dx12/tw3se/plugins             cj_core.dll, cj_qt.dll and its Qt (cj_qt/)
    Mods/modConjunction                    the editor's scripts (WitcherScript)
    Mods/modConjunctionRuntime             the scripts every quest calls, with its version (runtime.txt)
    dlc/dlcconjunctiontexts                the scene workshop's text pool (every language of the game)
    Conjunction/                           README.txt, LICENSE.txt, THIRD_PARTY_NOTICES.txt, licenses/
TW3SE itself is a mod of its own (a requirement on the page). Nothing of this PC goes in: no name, no path
(no_name.py checks the zip), no backup of a patch, no engine_only (the app's engine: it would start
without the editor).
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, ROOT)
from conjunction import w3strings  # noqa: E402

LUA = os.path.join(ROOT, "ingame", "lua", "conjunction")
# the runtime's version as the mod has it (packaging.lua: PK.RUNTIME_VERSION) - the public repository has no app
RUNTIME_VERSION = int(re.search(r"PK\.RUNTIME_VERSION\s*=\s*(\d+)",
                                open(os.path.join(LUA, "packaging.lua"), encoding="utf-8").read()).group(1))
PLUGIN = os.path.join(ROOT, "ingame", "plugin", "build")
QT_BIN = r"C:\Apps\Qt\6.11.2\bin"
QT_PLUGINS = r"C:\Apps\Qt\6.11.2\plugins"
QT_FILES = [(os.path.join(QT_BIN, n), n) for n in ("Qt6Core.dll", "Qt6Gui.dll", "Qt6OpenGL.dll")] + \
    [(os.path.join(QT_PLUGINS, "platforms", "qwindows.dll"), os.path.join("platforms", "qwindows.dll"))]
POOL_DLC, POOL_BASE, POOL_SIZE = "dlcconjunctiontexts", 2099000000, 4000     # (scene_texts.lua)
# no_name.py, the check for names and paths of this PC: its path in _scratch\no_name_path.txt or NO_NAME
NO_NAME = os.environ.get("NO_NAME") or (open(os.path.join(ROOT, "_scratch", "no_name_path.txt")).read().strip()
                                        if os.path.exists(os.path.join(ROOT, "_scratch", "no_name_path.txt"))
                                        else "")
# vtcheck.py (VirusTotal): its path in _scratch\vtcheck_path.txt or VTCHECK
VTCHECK = os.environ.get("VTCHECK") or (open(os.path.join(ROOT, "_scratch", "vtcheck_path.txt")).read().strip()
                                        if os.path.exists(os.path.join(ROOT, "_scratch", "vtcheck_path.txt"))
                                        else "")
TEXTS = os.path.join(ROOT, "tools", "release", "ingame")          # README.txt, THIRD_PARTY_NOTICES.txt
SKIP = shutil.ignore_patterns("*.bak*", "*.vor_*", "*.tmp", "__pycache__", "engine_only", "*.pyc")


def stage(top):
    tw = os.path.join(top, "bin", "x64_dx12", "tw3se")
    mod = os.path.join(tw, "mods", "conjunction")
    shutil.copytree(LUA, mod, ignore=SKIP)
    shutil.copytree(os.path.join(ROOT, "mod", "runtime", "scripts"), os.path.join(mod, "runtime", "scripts"), ignore=SKIP)
    shutil.copytree(os.path.join(ROOT, "conjunction", "sounds"), os.path.join(mod, "sounds"), ignore=SKIP)
    # (packs\conjunction_samples stays out: a computer voice nobody can name the source of, 14.11.; vgmstream too:
    # two of its DLLs flagged on VirusTotal, the exe loads all of them)
    os.makedirs(os.path.join(mod, "data"), exist_ok=True)
    shutil.copy2(os.path.join(ROOT, "conjunction", "data", "how_signing.html"), os.path.join(mod, "data"))
    plugins = os.path.join(tw, "plugins")
    os.makedirs(os.path.join(plugins, "cj_qt", "platforms"))
    for n in ("cj_core.dll", "cj_qt.dll"):
        shutil.copy2(os.path.join(PLUGIN, n), os.path.join(plugins, n))
    for src, rel in QT_FILES:
        shutil.copy2(src, os.path.join(plugins, "cj_qt", rel))
    # the editor's scripts and the runtime as setup.py puts them into the game
    shutil.copytree(os.path.join(ROOT, "mod", "scripts"), os.path.join(top, "Mods", "modConjunction", "content", "scripts"),
                    ignore=SKIP)
    rt = os.path.join(top, "Mods", "modConjunctionRuntime")
    shutil.copytree(os.path.join(ROOT, "mod", "runtime", "scripts"), os.path.join(rt, "content", "scripts"), ignore=SKIP)
    with open(os.path.join(rt, "runtime.txt"), "w", newline="\n") as f:
        f.write(f"{RUNTIME_VERSION}\n")
    # the scene workshop's pool: ids with marker texts, one file a language (deploy_mod.put_pool)
    content = os.path.join(top, "dlc", POOL_DLC, "content")
    os.makedirs(content)
    texts = {POOL_BASE + k: "cj %d" % k for k in range(POOL_SIZE)}
    for lang in sorted(w3strings.LANGS):
        with open(os.path.join(content, f"{lang}.w3strings"), "wb") as f:
            f.write(bytes(w3strings.write_v164(lang, texts)))
    # the texts beside it
    docs = os.path.join(top, "Conjunction")
    os.makedirs(docs)
    shutil.copy2(os.path.join(ROOT, "LICENSE"), os.path.join(docs, "LICENSE.txt"))
    for n in ("README.txt", "THIRD_PARTY_NOTICES.txt"):
        shutil.copy2(os.path.join(TEXTS, n), os.path.join(docs, n))
    shutil.copytree(os.path.join(TEXTS, "licenses"), os.path.join(docs, "licenses"))


NAME = re.compile(rb"MaximdeWinter(?![dD]e ?Winter|um|ize|al|a\b|e\b)")


def credits_name(top):
    """The sources' notes name the maker by his first name (who asked for what): in the release by his credits' name,
    MaximdeWinter, as no_name.py wants it - the lines stay where they are (a Lua error names its line)."""
    n = 0
    for r, _d, files in os.walk(top):
        for f in files:
            if f.lower().endswith((".lua", ".ws", ".txt", ".html", ".md", ".json", ".yml")):
                p = os.path.join(r, f)
                data = open(p, "rb").read()
                new, k = NAME.subn(b"MaximdeWinter", data)
                if k:
                    open(p, "wb").write(new)
                    n += k
    print("the maker's notes under his credits' name:", n)


def check(top):
    """What must not go out: a backup, the app's engine mark, an archive inside, a file of this PC's."""
    bad = []
    archives = (".zip", ".7z", ".rar", ".cab", ".tar", ".gz", ".jar", ".pptx", ".docx", ".xlsx", ".w3q", ".pyz",
                ".exe", ".bat", ".cmd", ".ps1", ".py")
    for r, _d, files in os.walk(top):
        for f in files:
            low = f.lower()
            if ".bak" in low or ".vor_" in low or low.endswith((".tmp",) + archives) or low == "engine_only":
                bad.append(os.path.relpath(os.path.join(r, f), top))
    if bad:
        raise SystemExit(f"not for a release: {bad[:10]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="0.1.0")
    ap.add_argument("--out", default=os.path.join(ROOT, "_scratch", "release", "ingame"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="cj_ingame_release_")
    try:
        stage(tmp)
        credits_name(tmp)
        check(tmp)
        pv = open(os.path.join(ROOT, "ingame", "lua", "conjunction", "provenance.lua"), encoding="utf-8").read()
        if f'PV.VERSION = "{a.version}"' not in pv:
            raise SystemExit(f"provenance.lua has another version than {a.version} (PV.VERSION) - no release")
        zpath = os.path.join(a.out, f"Conjunction-{a.version}.zip")
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for r, _d, files in os.walk(tmp):
                for f in sorted(files):
                    p = os.path.join(r, f)
                    z.write(p, os.path.relpath(p, tmp).replace(os.sep, "/"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if os.path.exists(NO_NAME):
        r = subprocess.run([sys.executable, NO_NAME, zpath], capture_output=True, text=True)
        hits = [ln.split(" :: ", 1)[1].rsplit("  (", 1)[0] for ln in r.stdout.splitlines() if ln.startswith("HIT ")]
        # Qt's own DLLs name the Qt Company's build folder: allowed when they are its files
        # unchanged
        qt = {"bin/x64_dx12/tw3se/plugins/cj_qt/" + rel.replace(os.sep, "/"): src for src, rel in QT_FILES}
        with zipfile.ZipFile(zpath) as z:
            own = [h for h in hits if not (h in qt and z.read(h) == open(qt[h], "rb").read())]
        if own or (r.returncode and not hits):
            print(r.stdout)
            raise SystemExit("traces of this PC in the zip (no_name.py above) - no release")
        print(f"names: none ({len(hits)} in Qt's own DLLs, unchanged: its build folder)")
    else:
        print(f"NOT CHECKED for names: {NO_NAME} is missing")
    h = hashlib.sha256(open(zpath, "rb").read()).hexdigest()
    with open(zpath + ".sha256", "w") as f:
        f.write(f"{h}  {os.path.basename(zpath)}\n")
    with zipfile.ZipFile(zpath) as z:
        n = len(z.namelist())
    print(f"{zpath}  {n} files  {os.path.getsize(zpath) / 1e6:.1f} MB  sha256 {h[:16]}...")
    if os.path.exists(VTCHECK):
        # the zip and every DLL in it on its own (06.11.: the zip was 0/68, cj_core.dll alone 1/68 - Nexus scans
        # the files too, and nothing may stop the upload)
        rc = subprocess.run([sys.executable, VTCHECK, zpath, "--deep"]).returncode
        if rc:
            print("VirusTotal: NOT clean or not checked - do not upload to Nexus (report beside the zip)")
    else:
        print(f"NOT CHECKED by VirusTotal: {VTCHECK} is missing")


if __name__ == "__main__":
    main()

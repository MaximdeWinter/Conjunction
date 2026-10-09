# PyInstaller: the suite as one folder with Conjunction.exe - nothing to install (no Python).
#     pyinstaller --noconfirm tools/release/conjunction.spec      (from the repository's folder) -> dist/Conjunction
# The suite finds its files beside its package (mod, packs, examples, plugins): they go next to it in _internal.
import os

from PyInstaller.utils.hooks import collect_submodules

ROOT = os.path.abspath(os.path.join(SPECPATH, "..", ".."))


def tree(rel, dest=None):
    """(source, destination folder) of every file below ROOT/rel, skipping caches and builds."""
    out = []
    for r, dirs, files in os.walk(os.path.join(ROOT, rel)):
        dirs[:] = [d for d in dirs if d not in ("__pycache__", "build", "out", "parked")]
        for f in files:
            if f.endswith((".pyc", ".bak")) or ".bak_" in f:
                continue
            src = os.path.join(r, f)
            out.append((src, os.path.dirname(os.path.relpath(src, ROOT)) if dest is None else dest))
    return out


USER_DOCS = ("first-quest.md", "quest-graph.md", "content-creators.md", "content-packs.md",
             "world-changes.md")   # (the others are notes of the suite's making; editing-game-quests.md: experimental,
# off in the release; 09.10.: no .pptx - it is a zip, and Nexus quarantines a zip inside a zip)
datas = (tree("conjunction/icons") + tree("conjunction/sounds") + tree("conjunction/data") +
         [(os.path.join(ROOT, "conjunction", "camera_shots.json"), "conjunction")] +
         tree("mod") + tree("packs") + tree("examples/bandit_camp") + tree("examples/the_choice") +
         tree("plugins") + tree("docs/guide") +
         [(os.path.join(ROOT, "docs", f), "docs") for f in USER_DOCS if os.path.exists(os.path.join(ROOT, "docs", f))] +
         [(os.path.join(ROOT, f), ".") for f in ("README.md", "LICENSE", "CHANGELOG.md") if
          os.path.exists(os.path.join(ROOT, f))])

a = Analysis(
    [os.path.join(SPECPATH, "launch.py")],
    pathex=[ROOT],
    datas=datas,
    hiddenimports=collect_submodules("conjunction") + ["lz4.block", "PIL.Image", "yaml"] +
        collect_submodules("cryptography.hazmat.primitives"),
    excludes=["tkinter", "matplotlib", "numpy", "scipy", "mujoco", "torch", "PySide6.Qt3DCore", "PySide6.QtWebEngineCore",
              "PySide6.QtWebEngineWidgets", "PySide6.QtQuick", "PySide6.QtQml", "PySide6.QtMultimedia"],
    noarchive=True,             # (09.10.: no base_library.zip - Nexus quarantines a zip inside a zip)
)
pyz = PYZ(a.pure)


def version_info():
    """Name, maker and version in the exe's properties (09.10.: an exe without them looks like malware to the virus
    scanners Nexus asks)."""
    from PyInstaller.utils.win32.versioninfo import (FixedFileInfo, StringFileInfo, StringStruct, StringTable,
                                                     VarFileInfo, VarStruct, VSVersionInfo)
    import re
    ver = re.search(r'__version__ = "([\d.]+)"', open(os.path.join(ROOT, "conjunction", "__init__.py")).read())[1]
    nums = tuple(int(n) for n in (ver.split(".") + ["0"] * 4)[:4])
    strings = [("CompanyName", "MaximdeWinter"), ("FileDescription", "Conjunction - quest editor for The Witcher 3"),
               ("FileVersion", ver), ("InternalName", "Conjunction"), ("LegalCopyright", "MaximdeWinter"),
               ("OriginalFilename", "Conjunction.exe"), ("ProductName", "Conjunction"), ("ProductVersion", ver)]
    return VSVersionInfo(ffi=FixedFileInfo(filevers=nums, prodvers=nums),
                         kids=[StringFileInfo([StringTable("040904B0", [StringStruct(k, v) for k, v in strings])]),
                               VarFileInfo([VarStruct("Translation", [1033, 1200])])])


exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="Conjunction", console=False,
          icon=os.path.join(ROOT, "conjunction", "data", "conjunction.ico"), version=version_info())
coll = COLLECT(exe, a.binaries, a.datas, name="Conjunction")

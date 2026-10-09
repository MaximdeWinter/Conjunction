"""The release: the suite as one folder (PyInstaller), checked by its self test, zipped.

    python tools/release/make_release.py [--out DIR]     -> DIR/Conjunction-<version>.zip (+ .sha256)

The self test runs the built Conjunction.exe with a scratch APPDATA and user folder and no screen (nothing of this PC's
suite or game is touched): every module loads, the files it brings are there, Qt starts.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def no_extender():
    """TW3SE is a requirement from its own Nexus page (Maxim 08.10.): no copy goes with Conjunction (an old one in
    ROOT/extender goes)."""
    shutil.rmtree(os.path.join(ROOT, "extender"), ignore_errors=True)
    print("extender: none (TW3SE is a requirement)")


def own_bootloader(work):
    """A copy of this Python's PyInstaller with the bootloader built here (build_bootloader.py), for PYTHONPATH: the
    prebuilt one is in every PyInstaller program, malware too, and virus scanners flag it (09.10.)."""
    import PyInstaller
    mine = os.path.join(ROOT, "tools", "release", "bootloader")
    have = open(os.path.join(mine, "VERSION")).read().strip() if os.path.exists(os.path.join(mine, "VERSION")) else None
    if have != PyInstaller.__version__:
        raise SystemExit(f"bootloader is for PyInstaller {have}, this is {PyInstaller.__version__}: "
                         "python tools/release/build_bootloader.py")
    pyi = os.path.join(work, "pyi")
    shutil.rmtree(pyi, ignore_errors=True)
    shutil.copytree(os.path.dirname(PyInstaller.__file__), os.path.join(pyi, "PyInstaller"),
                    ignore=shutil.ignore_patterns("__pycache__"))
    dst = os.path.join(pyi, "PyInstaller", "bootloader", "Windows-64bit-intel")
    for f in ("run.exe", "runw.exe"):
        shutil.copy2(os.path.join(mine, f), os.path.join(dst, f))
    print("bootloader: own build for PyInstaller", have)
    return pyi


TOP = {"Conjunction.exe", "_internal", "Guide.pdf", "LICENSE.txt"}   # all a user sees after unpacking (Maxim 09.10.)


def bring_guide(dist):
    """The guide beside Conjunction.exe as Guide.pdf: one PDF of the slides (Maxim 09.10.: the .pptx stays here, it
    makes the PDF; at the top only the exe and a few files)."""
    top = os.path.join(dist, "Conjunction")
    shutil.rmtree(os.path.join(top, "docs"), ignore_errors=True)          # (the folder of before 09.10.)
    shutil.copy2(os.path.join(ROOT, "docs", "first-quest.pdf"), os.path.join(top, "Guide.pdf"))
    print("guide: Guide.pdf")


def bring_notices(dist):
    """Who made the software inside Conjunction.exe and its licenses (09.10.: Qt for Python is LGPL-3.0, its text and
    the notice have to go along) - THIRD_PARTY_NOTICES.txt and the licenses folder in _internal, Conjunction's own
    LICENSE.txt beside the exe."""
    src = os.path.join(ROOT, "third_party")
    top = os.path.join(dist, "Conjunction")
    inner = os.path.join(top, "_internal")
    for old in ("THIRD_PARTY_NOTICES.txt", "licenses"):                     # (beside the exe before 09.10.)
        p = os.path.join(top, old)
        shutil.rmtree(p) if os.path.isdir(p) else (os.remove(p) if os.path.exists(p) else None)
    shutil.copy2(os.path.join(src, "THIRD_PARTY_NOTICES.txt"), os.path.join(inner, "THIRD_PARTY_NOTICES.txt"))
    shutil.copy2(os.path.join(ROOT, "LICENSE"), os.path.join(top, "LICENSE.txt"))      # Conjunction's own (09.10.)
    shutil.rmtree(os.path.join(inner, "licenses"), ignore_errors=True)
    shutil.copytree(os.path.join(src, "licenses"), os.path.join(inner, "licenses"))
    named = open(os.path.join(src, "THIRD_PARTY_NOTICES.txt"), encoding="utf-8").read()
    have = set(os.listdir(os.path.join(inner, "licenses")))
    import re
    missing = sorted({f for f in re.findall(r"licenses/([\w.-]+\.txt)", named)} - have)
    if missing or not os.path.isdir(os.path.join(dist, "Conjunction", "_internal", "PySide6")):
        raise SystemExit(f"notices: missing {missing}")
    print("notices:", len(have), "licenses")


def main():
    sys.path.insert(0, ROOT)
    from conjunction import __version__
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "_scratch", "release", "out"))
    ap.add_argument("--skip-build", action="store_true", help="zip what dist holds")
    ap.add_argument("--with-radish", action="store_true", help="also the GitHub release with radish's zip inside")
    a = ap.parse_args()
    dist = os.path.join(a.out, "dist")
    no_extender()
    if not a.skip_build:
        pyi = own_bootloader(os.path.join(a.out, "work"))
        subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--distpath", dist, "--workpath",
                        os.path.join(a.out, "work"), os.path.join(ROOT, "tools", "release", "conjunction.spec")],
                       check=True, cwd=ROOT, env=dict(os.environ, PYTHONPATH=pyi))
    bring_guide(dist)
    bring_notices(dist)
    exe = os.path.join(dist, "Conjunction", "Conjunction.exe")
    # the self test in a sandbox
    tmp = tempfile.mkdtemp()
    try:
        env = dict(os.environ, APPDATA=os.path.join(tmp, "appdata"), USERPROFILE=os.path.join(tmp, "home"),
                   LOCALAPPDATA=os.path.join(tmp, "local"), QT_QPA_PLATFORM="offscreen")
        env.pop("CJ_EXPERIMENTAL", None)
        for k in ("APPDATA", "USERPROFILE", "LOCALAPPDATA"):
            os.makedirs(env[k])
        # radish as a user has it: its Nexus zip downloaded (the release brings none - a zip inside a zip)
        from conjunction import radish_tools as R
        os.makedirs(os.path.join(env["USERPROFILE"], "Downloads"))
        shutil.copy2(os.path.join(ROOT, "third_party", "radish", R.ZIP_NAME),
                     os.path.join(env["USERPROFILE"], "Downloads", R.ZIP_NAME))
        report = os.path.join(tmp, "selftest.txt")
        subprocess.run([exe, "--selftest", report], env=env, timeout=300)
        text = open(report, encoding="utf-8").read() if os.path.exists(report) else "no report"
        print(text)
        if not text.startswith("ok"):
            raise SystemExit("the self test failed - no release")
        # everything of Conjunction in Documents\Conjunction, nothing in APPDATA / LOCALAPPDATA or the user folder
        home = os.path.join(env["USERPROFILE"], "Documents", "Conjunction")
        stray = [os.path.relpath(os.path.join(r, f), tmp) for k in ("APPDATA", "LOCALAPPDATA", "USERPROFILE")
                 for r, _d, files in os.walk(env[k]) for f in files
                 if "conjunction" in os.path.relpath(os.path.join(r, f), env[k]).lower()
                 and not os.path.join(r, f).startswith(home + os.sep)]
        if stray:
            raise SystemExit(f"Conjunction wrote outside Documents\\Conjunction: {stray} - no release")
        print("folders:", sorted(os.listdir(home)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    zpath = os.path.join(a.out, f"Conjunction-{__version__}.zip")
    base = os.path.join(dist, "Conjunction")
    if set(os.listdir(base)) != TOP:
        raise SystemExit(f"beside Conjunction.exe: {sorted(os.listdir(base))}, wanted {sorted(TOP)} - no release")
    # the files at the zip's top (09.10.): Extract All makes the folder, Conjunction.exe is the first thing in it
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for r, _d, files in os.walk(base):
            for f in files:
                p = os.path.join(r, f)
                z.write(p, os.path.relpath(p, base))
    # nothing inside that is an archive itself (09.10.: Nexus quarantined the release for a zip inside the zip)
    archives = (".zip", ".7z", ".rar", ".cab", ".tar", ".gz", ".jar", ".pptx", ".docx", ".xlsx", ".w3q", ".pyz")
    with zipfile.ZipFile(zpath) as z:
        inside = [n for n in z.namelist() if n.lower().endswith(archives)]
    if inside:
        os.remove(zpath)
        raise SystemExit(f"archives inside the release (Nexus quarantines them): {inside} - no release")
    h = hashlib.sha256(open(zpath, "rb").read()).hexdigest()
    open(zpath + ".sha256", "w").write(f"{h}  {os.path.basename(zpath)}\n")
    print(f"{zpath}  {os.path.getsize(zpath) / 1e6:.0f} MB  sha256 {h[:16]}...")
    # (no installer: Nexus put TW3SE in quarantine for one, 08.10. - the zip is the release)
    vt_check(zpath)
    if a.with_radish:
        with_radish(zpath)


def with_radish(zpath):
    """The GitHub release (Maxim 09.10.): the Nexus zip plus radish's own Nexus zip, unchanged, in
    _internal\\third_party\\radish - rmemr's wish ("the unmodified nexusmod zip, so it's easier to verify by users"),
    and the first start finds it there (radish_tools.bundled_zip). Nexus takes no zip inside a zip, so this one is
    for GitHub only."""
    from conjunction import radish_tools as R
    src = os.path.join(ROOT, "third_party", "radish")
    if not R.is_radish_zip(os.path.join(src, R.ZIP_NAME)):
        raise SystemExit(f"third_party\\radish\\{R.ZIP_NAME} is missing or not radish's Nexus zip - no GitHub release")
    out = zpath[:-4] + "-with-radish.zip"
    with zipfile.ZipFile(zpath) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for i in zin.infolist():
            z.writestr(i, zin.read(i))
        for f in (R.ZIP_NAME, "README.txt"):
            z.write(os.path.join(src, f), f"_internal/third_party/radish/{f}",
                    zipfile.ZIP_STORED if f.endswith(".zip") else zipfile.ZIP_DEFLATED)
    h = hashlib.sha256(open(out, "rb").read()).hexdigest()
    open(out + ".sha256", "w").write(f"{h}  {os.path.basename(out)}\n")
    print(f"{out}  {os.path.getsize(out) / 1e6:.0f} MB  sha256 {h[:16]}...  (GitHub only)")
    vt_check(out)


VTCHECK = os.environ.get("VTCHECK", r"C:\Desktop\Ablage\Projekte\vtcheck\vtcheck.py")   # (another PC: its own)


def vt_check(zpath):
    """Every upload to Nexus goes through VirusTotal first and needs 0 hits (Maxim 09.10.; Nexus quarantines at 5).
    The zip first (what Nexus checks); only on a hit each binary inside too (--deep), so it says which file it is."""
    if os.path.exists(VTCHECK):
        rc = subprocess.run([sys.executable, VTCHECK, zpath]).returncode
        if rc == 1:
            subprocess.run([sys.executable, VTCHECK, zpath, "--deep"])
    else:
        print(f"NOT CHECKED: {VTCHECK} is missing")
        rc = 2
    if rc:
        print("VirusTotal: NOT clean or not checked - do not upload to Nexus (report beside the zip)")


if __name__ == "__main__":
    main()

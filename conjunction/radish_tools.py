"""radish modding tools (by rmemr, nexusmods.com/witcher3/mods/3620) shipped with Conjunction (rmemr 05.10.: "as long
as they are unmodified, contain the crc txt files to verify the validity, sure" - "I'd probably like to have the
unmodified nexusmod zip(s) ... unpacked/installed afterwards by some installer").

The user downloads the Nexus zip (09.10.: radish is a requirement on Conjunction's page - Nexus quarantines a zip
inside a zip). The first start finds it in Downloads (or Vortex's downloads), or the user picks it, and unpacks it into Documents\\Conjunction\\tools\\radish-tools and checks every exe and dll against radish's own
`crc.radish-modding-tools.current.txt`. A radish folder the user has already is only checked, never changed.

    install(log)            -> the folder (unpacked or the one set), or raises Bad
    check(folder)           -> [what does not match] (empty: as radish shipped it)
"""
import hashlib
import os
import re
import sys
import zipfile

ZIP_NAME = "radish.modding.tools-v2020-11-21-3620-v2020-11-21-1606002572.zip"
ZIP_SHA256 = "f7417b7fb65160a7e11b8d9b32f597ae7a8f229ddd1e22797edb983526813b1c"
ZIP_SIZE = 25611051
CRC = "crc.radish-modding-tools.current.txt"
NEXUS = "https://www.nexusmods.com/witcher3/mods/3620"
HERE = os.path.dirname(os.path.abspath(__file__))


class Bad(RuntimeError):
    """The zip or a radish folder is not as radish shipped it."""


def bundled_zip():
    """The Nexus zip in the release (or in the repository's third_party for a build from the source) -> path / None."""
    roots = [os.path.dirname(sys.executable)] if getattr(sys, "frozen", False) else []
    roots += [os.path.dirname(HERE), getattr(sys, "_MEIPASS", "")]
    for r in roots:
        p = os.path.join(r, "third_party", "radish", ZIP_NAME)
        if r and os.path.isfile(p):
            return p
    return None


def download_dirs():
    """Where a downloaded radish zip lands: the user's Downloads, Vortex's downloads for The Witcher 3."""
    out = [os.path.join(os.path.expanduser("~"), "Downloads")]
    if os.environ.get("APPDATA"):
        out.append(os.path.join(os.environ["APPDATA"], "Vortex", "downloads", "witcher3"))
    return out


def is_radish_zip(path):
    """Is it radish's Nexus zip, as downloaded (its size, then its sha256)?"""
    try:
        return os.path.getsize(path) == ZIP_SIZE and sha256(path) == ZIP_SHA256
    except OSError:
        return False


def find_zip():
    """radish's Nexus zip (09.10.: a requirement from its own page - Nexus takes no zip inside a zip): the repository's
    for a build from the source, else a download of it (any name: a browser may add "(1)") -> path / None."""
    z = bundled_zip()
    if z:
        return z
    for d in download_dirs():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            p = os.path.join(d, n)
            if n.lower().startswith("radish") and n.lower().endswith(".zip") and is_radish_zip(p):
                return p
    return None


def target():
    from .paths import TOOLS
    return os.path.join(TOOLS, "radish-tools")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def expected(folder):
    """{file: sha256} from radish's crc list in the folder."""
    p = os.path.join(folder, CRC)
    if not os.path.isfile(p):
        raise Bad(f"{CRC} is missing in {folder}")
    text = open(p, encoding="utf-8", errors="replace").read()
    return {name: sha for name, sha in re.findall(r"^(\S+\.(?:exe|dll))\s*\n(?:[ \t]+.*\n)*?[ \t]+sha256: (\w+)",
                                                  text, re.M)}


def check(folder):
    """-> [problem] for every exe / dll of radish's list that is missing or differs (empty: unmodified)."""
    try:
        want = expected(folder)
    except Bad as ex:
        return [str(ex)]
    if not want:
        return [f"{CRC} lists no files"]
    out = []
    for name, sha in sorted(want.items()):
        p = os.path.join(folder, name)
        if not os.path.isfile(p):
            out.append(f"{name}: missing")
        elif sha256(p) != sha:
            out.append(f"{name}: changed (not as radish shipped it)")
    return out


def unpack(zip_path, dest, log=print):
    """The Nexus zip into dest (its top folder radish-tools\\ becomes dest). -> dest."""
    if sha256(zip_path) != ZIP_SHA256:
        raise Bad(f"{os.path.basename(zip_path)} is not the zip from Nexus (its sha256 differs)")
    tmp = dest + ".unpacking"
    if os.path.isdir(tmp):
        import shutil
        shutil.rmtree(tmp)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            parts = info.filename.replace("\\", "/").split("/", 1)
            if len(parts) < 2 or not parts[1] or ".." in parts[1].split("/"):
                continue
            out = os.path.join(tmp, *parts[1].split("/"))
            if info.is_dir():
                os.makedirs(out, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with z.open(info) as src, open(out, "wb") as f:
                f.write(src.read())
    bad = check(tmp)
    if bad:
        raise Bad("radish unpacked, but: " + "; ".join(bad[:3]))
    if os.path.isdir(dest):
        import shutil
        shutil.rmtree(dest)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    os.replace(tmp, dest)
    log(f"radish modding tools unpacked into {dest} and checked against {CRC}")
    return dest


def install(current="", log=print):
    """The radish folder to use: `current` (the config's) when it is there and unmodified, else the shipped zip
    unpacked (once). -> folder; raises Bad when neither works."""
    if current and os.path.isfile(os.path.join(current, "w2quest.exe")):
        bad = check(current)
        if not bad:
            return current
        log(f"radish in {current} is not as radish shipped it: {'; '.join(bad[:3])}")
    dest = target()
    if os.path.isfile(os.path.join(dest, "w2quest.exe")) and not check(dest):
        return dest
    z = find_zip()
    if not z:
        raise Bad(f"No radish modding tools. Please download them from {NEXUS}")
    return unpack(z, dest, log)


def install_from(zip_path, log=print):
    """A radish zip the user picked -> the folder it is unpacked into; raises Bad when it is not radish's."""
    if not is_radish_zip(zip_path):
        raise Bad(f"This is not the radish zip from {NEXUS} ({ZIP_NAME})")
    return unpack(zip_path, target(), log)

"""An installer for what goes on Nexus Mods (06.10.): the files of a package appended to installer\\installer.cpp's
program, which finds the game (Steam, GOG, Epic), shows what goes where and what the package needs, installs and
removes. The same program for TW3SE, the Conjunction Runtime and every exported quest.

    build(out_exe, header, files)          header: [(key, value)] (installer.cpp names the keys); files: [(path in
                                           the game folder, bytes or a file)]
    from_zip(zip_path, out_exe, header)    every file of a zip laid out as the game's folders
    quest_header(m) / runtime_header(n) / tw3se_header(version)
"""
import os
import struct
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STUBS = (os.path.join(ROOT, "installer", "build", "installer_stub.exe"),     # a working copy (installer\build_installer.bat)
         os.path.join(ROOT, "installer", "installer_stub.exe"))              # the released suite (conjunction.spec)
MAGIC = b"CJINSTv1"
RUNTIME_FILE = "Mods\\modConjunctionRuntime\\runtime.txt"


def stub():
    for s in STUBS:
        if os.path.exists(s):
            return s
    raise FileNotFoundError("no installer program (installer\\build_installer.bat)")


def lzms(data):
    """`data` packed with Windows' own LZMS (cabinet.dll, buffer mode) - what the installer's Decompress reads."""
    import ctypes
    cab = ctypes.WinDLL("cabinet")
    h = ctypes.c_void_p()
    if not cab.CreateCompressor(5, None, ctypes.byref(h)):           # COMPRESS_ALGORITHM_LZMS
        raise OSError("no LZMS compressor")
    try:
        need = ctypes.c_size_t()
        cab.Compress(h, data, ctypes.c_size_t(len(data)), None, ctypes.c_size_t(0), ctypes.byref(need))
        out = ctypes.create_string_buffer(need.value)
        if not cab.Compress(h, data, ctypes.c_size_t(len(data)), out, need, ctypes.byref(need)):
            raise OSError("LZMS compression failed")
        return out.raw[:need.value]
    finally:
        cab.CloseCompressor(h)


def build(out_exe, header, files, packed=False):
    """`packed`: every file LZMS-packed (header packed=lzms; each entry also gives its size unpacked)."""
    if packed:
        header = list(header) + [("packed", "lzms")]
    text = "\n".join(f"{k}={v}" for k, v in header) + "\n--files--\n"
    parts = [text.encode("utf-8")]
    for path, data in files:
        if not isinstance(data, (bytes, bytearray)):
            data = open(data, "rb").read()
        p = path.replace("/", "\\").encode("utf-8")
        if packed:
            stored = lzms(bytes(data)) if data else b""
            parts += [struct.pack("<I", len(p)), p, struct.pack("<Q", len(stored)), struct.pack("<Q", len(data)),
                      stored]
        else:
            parts += [struct.pack("<I", len(p)), p, struct.pack("<Q", len(data)), bytes(data)]
    payload = b"".join(parts)
    with open(out_exe, "wb") as f:
        f.write(open(stub(), "rb").read())
        f.write(payload)
        f.write(struct.pack("<Q", len(payload)) + MAGIC)
    return out_exe


def from_zip(zip_path, out_exe, header, skip=()):
    with zipfile.ZipFile(zip_path) as z:
        files = [(n, z.read(n)) for n in z.namelist() if not n.endswith("/") and not any(n.startswith(s) for s in skip)]
    return build(out_exe, header, files)


def quest_header(m):
    """A quest (packaging.manifest): its DLC (and its mod of changed game files) replaced whole on an update; the
    runtime, TW3SE, expansions and packs it needs shown with whether the game has them."""
    qid = m["id"]
    place = m.get("kind") == "place"
    made = "A place mod made with Conjunction." if place else "A quest made with Conjunction."
    h = [("name", m.get("title") or qid), ("version", m.get("version") or ""),
         ("about", (m.get("description") or made).splitlines()[0][:200]),
         ("clean", f"dlc\\dlc{qid}"), ("clean", f"Mods\\moddlc{qid}"),
         ("installed", f"dlc\\dlc{qid}\\conjunction_quest.yml"),
         ("remove_warning", "Removing it takes its places out of the world." if place else
                            "Finish the quest before you remove it, or load a save from before you started it. "
                            "A save from its middle keeps what it changed in the world."),
]
    if int(m.get("runtime", 1)):                    # (quests before 08.10.: the runtime's functions; later ones carry theirs)
        h.append(("need", f"version|{RUNTIME_FILE}|Conjunction Runtime|{m.get('runtime', 1)}"))
    if m.get("tw3se"):
        h += [("dx12", "1"), ("need", "file|bin\\x64_dx12\\tw3se\\tw3se.dll|TW3SE")]
    for e in m.get("expansions") or []:              # (on patch 5.0 they are in content0: shown, not checked)
        h.append(("need", f"info||{e}"))
    for p in m.get("packs") or []:
        detect = (p.get("detect") or [None])[0]
        if detect:
            h.append(("need", f"file|{detect.replace('/', chr(92))}|{p.get('name')}"))
    return h


def runtime_files():
    """The Conjunction Runtime as files in the game folder: its scripts (what setup.install_runtime puts in, the item
    table that comes with Conjunction) and its version."""
    from .packaging import RUNTIME_VERSION
    from .setup import RUNTIME_MARK, RUNTIME_MOD, RUNTIME_SCRIPTS
    out = []
    for root, _d, files in os.walk(RUNTIME_SCRIPTS):
        for f in sorted(files):
            if f.endswith(".ws"):                           # (no .bak of a patch)
                p = os.path.join(root, f)
                out.append((f"Mods\\{RUNTIME_MOD}\\content\\scripts\\" + os.path.relpath(p, RUNTIME_SCRIPTS), p))
    out.append((f"Mods\\{RUNTIME_MOD}\\{RUNTIME_MARK}", f"{RUNTIME_VERSION}\n".encode()))
    return out


def quest_installer(zip_path, out_exe, m):
    """A quest's installer: its DLC only, and the runtime version it needs shown when the game has an older one or
    none (Maxim 06.10.: the runtime is its own download - Conjunction brings it too - and so has no size limit; the
    installer could carry it as a shared part, runtime_files(), but a quest does not)."""
    return from_zip(zip_path, out_exe, quest_header(m))


def runtime_header(n):
    return [("name", "Conjunction Runtime"), ("version", str(n)),
            ("about", "The scripts that quests made with Conjunction need."),
            ("clean", "Mods\\modConjunctionRuntime\\content\\scripts"),
            ("installed", RUNTIME_FILE),
            ("newer", f"{RUNTIME_FILE}|{n}|Conjunction Runtime")]


def tw3se_header(version):
    return [("name", "TW3SE"), ("version", version), ("dx12", "1"), ("dinput8", "keep"),
            ("about", "The Witcher 3 Script Extender.")]


def app_header(version, name="Conjunction"):
    """Conjunction itself (Maxim 07.10.: one installer that sets it up where it was): its program folder replaced
    (_internal emptied first), the user's things in Documents\\Conjunction untouched."""
    return [("name", name), ("version", version),
            ("about", "Quests and places for The Witcher 3, made in the running game."),
            ("app", "Conjunction.exe"), ("clean", "_internal"), ("installed", "version.txt")]


def app_installer(zip_path, out_exe, version, name="Conjunction"):
    """The release zip (one folder Conjunction\\...) as the app's installer: paths relative to its folder."""
    with zipfile.ZipFile(zip_path) as z:
        top = z.namelist()[0].split("/")[0] + "/"
        files = [(n[len(top):], z.read(n)) for n in z.namelist() if n.startswith(top) and not n.endswith("/")]
    files.append(("version.txt", (version + "\n").encode()))
    return build(out_exe, app_header(version, name), files, packed=True)     # (about the zip's size)

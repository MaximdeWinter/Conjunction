"""PyInstaller's bootloader built here (MSVC 2022), for the PyInstaller this Python has.

    python tools/release/build_bootloader.py      -> tools/release/bootloader/ (run*.exe + VERSION)

Every PyInstaller program in the world starts with the same prebuilt bootloader, malware too, so virus scanners flag
it (09.10.: Nexus quarantines at 5 VirusTotal hits). One built here has bytes of its own. make_release builds with it
and refuses when PyInstaller was updated and the bootloader is from another version: then run this again.
"""
import glob
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

import PyInstaller

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "bootloader")
VCVARS = r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"


def main():
    ver = PyInstaller.__version__
    tmp = tempfile.mkdtemp()
    try:
        subprocess.run([sys.executable, "-m", "pip", "download", f"pyinstaller=={ver}", "--no-binary", ":all:",
                        "--no-deps", "-q", "-d", tmp], check=True)
        with tarfile.open(glob.glob(os.path.join(tmp, "*.tar.gz"))[0]) as t:
            t.extractall(tmp, filter="data")
        src = os.path.join(tmp, f"pyinstaller-{ver}")
        bat = os.path.join(tmp, "build.bat")
        with open(bat, "w") as f:
            f.write(f'@call "{VCVARS}" >nul\r\n@cd /d "{os.path.join(src, "bootloader")}"\r\n'
                    f'@"{sys.executable}" waf distclean all --target-arch=64bit --msvc_targets=x64\r\n')
        subprocess.run(["cmd", "/c", bat], check=True)
        built = os.path.join(src, "PyInstaller", "bootloader", "Windows-64bit-intel")
        shutil.rmtree(OUT, ignore_errors=True)
        os.makedirs(OUT)
        for f in ("run.exe", "runw.exe"):
            shutil.copy2(os.path.join(built, f), os.path.join(OUT, f))
        open(os.path.join(OUT, "VERSION"), "w").write(ver + "\n")
        print("bootloader", ver, "->", OUT)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()

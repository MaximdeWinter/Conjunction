# Building Conjunction

Conjunction is a Python application. The release is one folder with Conjunction.exe, made with PyInstaller.

## What is needed?

- Windows 10 or 11 (64-bit)
- Python 3.14 (64-bit)
- Visual Studio 2022 Build Tools with **Desktop development with C++** (for PyInstaller's bootloader)
- [radish modding tools](https://www.nexusmods.com/witcher3/mods/3620) v2020-11-21: the zip goes unchanged into
  `third_party\radish\` (the release's self test unpacks it the way a user's first start does)

## Run from source

```
pip install -r requirements.txt
python -m conjunction
```

## Build the release

```
pip install -r requirements.txt pyinstaller==6.20.0
python tools\release\build_bootloader.py
python tools\release\make_release.py
```

1. `build_bootloader.py` downloads PyInstaller's source for the installed version and builds its bootloader with
   MSVC into `tools\release\bootloader\`. The release uses this bootloader in place of the prebuilt one.
2. `make_release.py` builds Conjunction.exe with `tools\release\conjunction.spec`, runs a self test of the exe in a
   scratch user folder and zips the folder.

The zip is `_scratch\release\out\Conjunction-<version>.zip`, with its sha256 beside it.

`make_release.py --with-radish` also makes **Conjunction-<version>-with-radish.zip** for GitHub: the same files and
radish's Nexus zip, unchanged, in `third_party\radish\`.

`make_release.py` stops when PyInstaller was updated and the bootloader is from another version. Run
`build_bootloader.py` again then.

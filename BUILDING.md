# Building Conjunction

Conjunction is a TW3SE mod: Lua (`ingame/lua/conjunction`, needs no build), two DLLs in C++ (`ingame/plugin`) and
WitcherScript (`mod/scripts`, `mod/runtime/scripts`).

## What is needed?

- Windows 10 or 11 (64-bit)
- Visual Studio 2022 Build Tools with **Desktop development with C++**
- TW3SE's headers (the `include` folder of TW3SE's SDK)
- Qt 6.11.2 for MSVC 2022 64-bit (Qt6Core, Qt6Gui, Qt6OpenGL)
- Python 3.14 (64-bit), for the release zip

## Build the plug-ins

Set `TW` to TW3SE's folder (with its `include`; else `tw3se` beside this repository) and `QT` to Qt 6.11.2 (else
`C:\Apps\Qt\6.11.2`). Then:

```
ingame\plugin\build_plugin.bat
```

The DLLs are in `ingame\plugin\build`.

## Build the release

```
python tools\release\make_ingame_release.py
```

It puts the Lua files, the DLLs, Qt, the scripts and the texts in `tools\release\ingame` into
`_scratch\release\ingame\Conjunction-<version>.zip`, laid out as the game folder. The sha256 is beside it. The Qt
folder is set in `QT_BIN` and `QT_PLUGINS` at the top of the script.

Its checks for names (`NO_NAME`) and VirusTotal (`VTCHECK`) are scripts of their own, outside this repository. Without
them the zip is built unchecked.

@echo off
rem Builds cj_core.dll (cj_core.cpp, SQLite 3.50.4 with the options of the app's Python) into ingame\plugin\build.
rem The lab loads it from there; ingame\tools\deploy_mod.py copies it to <game>\bin\x64_dx12\tw3se\plugins.
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
cd /d %~dp0
rem TW3SE (its include folder): TW, else beside the repository
if not defined TW set TW=%~dp0..\..\..\tw3se
if not exist build\obj mkdir build\obj
rem Python's sqlite3 (pragma compile_options): FTS3/4/5, math functions, R*Tree, recursive triggers by default,
rem 32766 variables, temp tables in files unless asked for memory, Windows mutexes
set SQLDEFS=/DSQLITE_ENABLE_FTS3 /DSQLITE_ENABLE_FTS4 /DSQLITE_ENABLE_FTS5 /DSQLITE_ENABLE_MATH_FUNCTIONS ^
 /DSQLITE_ENABLE_RTREE /DSQLITE_DEFAULT_RECURSIVE_TRIGGERS=1 /DSQLITE_MAX_VARIABLE_NUMBER=32766 /DSQLITE_TEMP_STORE=1 ^
 /DSQLITE_THREADSAFE=1 /DSQLITE_OMIT_AUTOINIT /DSQLITE_MALLOC_SOFT_LIMIT=1024 /DSQLITE_DIRECT_OVERFLOW_READ
rem version data in each DLL (version.rc; DLLs without it look like malware to virus scanners, as TW3SE found)
if not exist build\obj\res mkdir build\obj\res
rc /nologo /d CJ_FILE=1 /fo build\obj\res\core.res version.rc || exit /b 1
rc /nologo /d CJ_FILE=2 /fo build\obj\res\qt.res version.rc || exit /b 1
cl /nologo /O2 /MT /c %SQLDEFS% /Fobuild\obj\sqlite3.obj deps\sqlite\sqlite3.c || exit /b 1
cl /nologo /O2 /MT /c /Fobuild\obj\ deps\lz4\lz4.c deps\lz4\lz4hc.c || exit /b 1
cl /nologo /O2 /MT /LD /EHsc /W3 /std:c++17 /D_CRT_SECURE_NO_WARNINGS /I%TW%\include /Ideps\sqlite /Ideps\stb /Fobuild\obj\ cj_core.cpp qtscale.cpp depot.cpp textures.cpp mosaic.cpp shellicons.cpp zip.cpp pystat.cpp crypto.cpp lz4pack.cpp buildsys.cpp keeprun.cpp tweetnacl_seed.c build\obj\sqlite3.obj build\obj\lz4.obj build\obj\lz4hc.obj build\obj\res\core.res ^
 /link /OUT:build\cj_core.dll /IMPLIB:build\obj\cj_core.lib user32.lib psapi.lib || exit /b 1
echo built build\cj_core.dll
rem cj_qt.dll: Qt's painter (the app's Qt 6.11.2, its SDK in C:\Apps\Qt\6.11.2; the DLLs load late, from beside it)
if not defined QT set QT=C:\Apps\Qt\6.11.2
cl /nologo /O2 /MD /LD /EHsc /W3 /std:c++17 /Zc:__cplusplus /permissive- /D_CRT_SECURE_NO_WARNINGS /DQT_NO_VERSION_TAGGING ^
 /I%TW%\include /I%QT%\include /I%QT%\include\QtCore /I%QT%\include\QtGui /I%QT%\include\QtOpenGL /Fobuild\obj\ cj_qt.cpp cj_qt_gl.cpp build\obj\res\qt.res ^
 /link /OUT:build\cj_qt.dll /IMPLIB:build\obj\cj_qt.lib /LIBPATH:%QT%\lib Qt6Core.lib Qt6Gui.lib Qt6OpenGL.lib ^
 /DELAYLOAD:Qt6Core.dll /DELAYLOAD:Qt6Gui.dll /DELAYLOAD:Qt6OpenGL.dll || exit /b 1
echo built build\cj_qt.dll

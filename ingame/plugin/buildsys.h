// What the build needs of Windows beyond w3.fs and w3.proc (buildsys.cpp): cj_hardlink, cj_exe_window_titles,
// cj_redkit_eula_keep, cj_file_attributes.
#pragma once
#include <stdint.h>

namespace buildsys {
int HardLink(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int FileAttributes(int argc, const char* const* argv, char* reply, uint32_t size, void*);
// at the plug-in's load (before the engine scans dlc\ and Mods\): the folders the last Build & Play into the running
// game left for later (<game>\_conjunction_parked\pending.txt: a line "<from>\t<to>" each, relative to the game's
// folder) moved out -> how many
int ParkPending();
int RedkitEulaKeep(int argc, const char* const* argv, char* reply, uint32_t size, void*);
}  // namespace buildsys

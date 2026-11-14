// The game keeps running while another window is in front (keeprun.cpp): cj_keep_running.
#pragma once
#include <stdint.h>

struct TW3SE_Interface;

namespace keeprun {
void Init(const TW3SE_Interface* api);
int KeepRunning(int argc, const char* const* argv, char* reply, uint32_t size, void*);
void Unload();
}  // namespace keeprun

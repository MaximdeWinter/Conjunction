// os.stat's size and st_mtime as Python gives them (pystat.cpp): cj_py_stat.
#pragma once
#include <stdint.h>

namespace pystat {
int Stat(int argc, const char* const* argv, char* reply, uint32_t size, void*);
}  // namespace pystat

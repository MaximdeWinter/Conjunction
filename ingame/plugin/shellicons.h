// Windows' own icons as Qt's file dialog and message boxes show them (shellicons.cpp): cj_shell_icon.
#pragma once
#include <stdint.h>

namespace shellicons {
int Icon(int argc, const char* const* argv, char* reply, uint32_t size, void*);
}  // namespace shellicons

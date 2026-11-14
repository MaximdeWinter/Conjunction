// Zip files: the library's quests (.w3q), the bug reports (zip.cpp): cj_zip_list, cj_zip_extract, cj_zip_write.
#pragma once
#include <stdint.h>

namespace zip {
int List(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Extract(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Write(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Zlib(int argc, const char* const* argv, char* reply, uint32_t size, void*);
}  // namespace zip

// The game's files out of its bundles (depot.cpp): cj_depot_open / exists / read / glob, cj_bundle_read.
#pragma once
#include <stdint.h>

namespace depot {
int Open(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Exists(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int ReadTo(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Glob(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int GlobWhere(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int BundleRead(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int OpenAsync(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Data(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int MeshRows(int argc, const char* const* argv, char* reply, uint32_t size, void*);
// TW3SE's LuaReplyBytes (interface 20), else nullptr: cj_depot_data gives a file's bytes to Lua with it
extern int (*g_reply_bytes)(const void* data, size_t size);
}  // namespace depot

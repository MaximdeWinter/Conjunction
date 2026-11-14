// Pictures out of the game's texture.cache files (textures.cpp): cj_tex_open / image / decode.
#pragma once
#include <stdint.h>

namespace textures {
int Open(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Image(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Decode(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int ImageAsync(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Status(int argc, const char* const* argv, char* reply, uint32_t size, void*);
}  // namespace textures

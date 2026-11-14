// The Asset Browser's folder pictures as the app's Pillow makes them (mosaic.cpp): cj_mosaic / _async / _status.
#pragma once
#include <stdint.h>

namespace mosaic {
int Now(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Async(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Status(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Thumb(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int ThumbAsync(int argc, const char* const* argv, char* reply, uint32_t size, void*);
}  // namespace mosaic

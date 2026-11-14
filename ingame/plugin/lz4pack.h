// LZ4 HC for the bundle packer (lz4pack.cpp): a file compressed as python-lz4's lz4.block.compress(raw,
// mode="high_compression", store_size=False) does it - LZ4 1.9.4, level 9.
#pragma once
#include <stdint.h>

namespace lz4pack {
int CompressFile(int argc, const char* const* argv, char* reply, uint32_t size, void*);
}  // namespace lz4pack

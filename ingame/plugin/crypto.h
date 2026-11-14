// A profile's signatures and the history's hashes (crypto.cpp).
#pragma once
#include <stdint.h>

namespace crypto {
int Ed25519Public(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Ed25519Sign(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Ed25519Verify(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Random(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int HmacSha256(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int Sha256Parts(int argc, const char* const* argv, char* reply, uint32_t size, void*);
}  // namespace crypto

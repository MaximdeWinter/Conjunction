// What a profile signs with and what the history and the maker's mark hash (identity.py, provenance.py, marks.py):
// ed25519 from a 32-byte seed (TweetNaCl: the signatures are the same as Python's cryptography makes - ed25519 is
// deterministic), HMAC-SHA256 and SHA-256 through Windows' CNG.
//
//   cj_ed25519_public(seed hex)                 -> public key hex
//   cj_ed25519_sign(seed hex, message)          -> signature hex (the message as UTF-8 text)
//   cj_ed25519_verify(public hex, message, signature hex) -> "1" | "0"
//   cj_random(n)                                -> n random bytes, hex
//   cj_hmac_sha256(key hex, message)            -> hex
//   cj_sha256_parts(part ...)                   -> hex of the parts one after the other: "t:<text>", "z" (a 0 byte),
//                                                  "x:<hex bytes>", "f:<path>" (the SHA-256 of that file's bytes,
//                                                  32 bytes), "F:<path>" (the file's own bytes)
#include "crypto.h"

#include <windows.h>
#include <bcrypt.h>

#include <stdio.h>
#include <string.h>

#include <string>
#include <vector>

extern "C" int cj_sign_seed_keypair(unsigned char* pk, unsigned char* sk, const unsigned char* seed);
extern "C" int crypto_sign_ed25519_tweet(unsigned char* sm, unsigned long long* smlen, const unsigned char* m,
                                         unsigned long long n, const unsigned char* sk);
extern "C" int crypto_sign_ed25519_tweet_open(unsigned char* m, unsigned long long* mlen, const unsigned char* sm,
                                              unsigned long long n, const unsigned char* pk);

namespace crypto {
namespace {

int Fail(char* reply, uint32_t size, const std::string& s) {
    snprintf(reply, size, "%s", s.c_str());
    return 0;
}
std::string Hex(const unsigned char* p, size_t n) {
    static const char* d = "0123456789abcdef";
    std::string s(n * 2, '0');
    for (size_t i = 0; i < n; ++i) {
        s[2 * i] = d[p[i] >> 4];
        s[2 * i + 1] = d[p[i] & 15];
    }
    return s;
}
bool Unhex(const char* s, std::vector<unsigned char>& out) {
    size_t n = strlen(s);
    if (n % 2) return false;
    out.resize(n / 2);
    auto v = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < n / 2; ++i) {
        int a = v(s[2 * i]), b = v(s[2 * i + 1]);
        if (a < 0 || b < 0) return false;
        out[i] = static_cast<unsigned char>(a * 16 + b);
    }
    return true;
}
std::wstring Wide(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
    return w;
}
bool ReadFile(const std::string& path, std::vector<unsigned char>& out) {
    FILE* f = _wfopen(Wide(path).c_str(), L"rb");
    if (!f) return false;
    unsigned char buf[65536];
    size_t got;
    out.clear();
    while ((got = fread(buf, 1, sizeof buf, f)) > 0) out.insert(out.end(), buf, buf + got);
    fclose(f);
    return true;
}

// SHA-256 (or HMAC-SHA256 with a key) over pieces
struct Hash {
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE h = nullptr;
    bool ok = false;
    explicit Hash(const std::vector<unsigned char>* key = nullptr) {
        if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr,
                                        key ? BCRYPT_ALG_HANDLE_HMAC_FLAG : 0) != 0) return;
        ok = BCryptCreateHash(alg, &h, nullptr, 0, key ? const_cast<PUCHAR>(key->data()) : nullptr,
                              key ? static_cast<ULONG>(key->size()) : 0, 0) == 0;
    }
    ~Hash() {
        if (h) BCryptDestroyHash(h);
        if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    }
    void Add(const void* p, size_t n) {
        if (ok && n) ok = BCryptHashData(h, static_cast<PUCHAR>(const_cast<void*>(p)), static_cast<ULONG>(n), 0) == 0;
    }
    std::vector<unsigned char> Done() {
        std::vector<unsigned char> out(32);
        if (ok) ok = BCryptFinishHash(h, out.data(), 32, 0) == 0;
        return out;
    }
};

}  // namespace

int Ed25519Public(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    std::vector<unsigned char> seed;
    if (argc < 1 || !Unhex(argv[0], seed) || seed.size() != 32) return Fail(reply, size, "cj_ed25519_public(seed hex)");
    unsigned char pk[32], sk[64];
    cj_sign_seed_keypair(pk, sk, seed.data());
    SecureZeroMemory(sk, sizeof sk);
    snprintf(reply, size, "%s", Hex(pk, 32).c_str());
    return 1;
}

int Ed25519Sign(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    std::vector<unsigned char> seed;
    if (argc < 2 || !Unhex(argv[0], seed) || seed.size() != 32)
        return Fail(reply, size, "cj_ed25519_sign(seed hex, message)");
    unsigned char pk[32], sk[64];
    cj_sign_seed_keypair(pk, sk, seed.data());
    size_t n = strlen(argv[1]);
    std::vector<unsigned char> sm(n + 64);
    unsigned long long smlen = 0;
    crypto_sign_ed25519_tweet(sm.data(), &smlen, reinterpret_cast<const unsigned char*>(argv[1]), n, sk);
    SecureZeroMemory(sk, sizeof sk);
    snprintf(reply, size, "%s", Hex(sm.data(), 64).c_str());
    return 1;
}

int Ed25519Verify(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    std::vector<unsigned char> pk, sig;
    if (argc < 3) return Fail(reply, size, "cj_ed25519_verify(public hex, message, signature hex)");
    if (!Unhex(argv[0], pk) || pk.size() != 32 || !Unhex(argv[2], sig) || sig.size() != 64) {
        snprintf(reply, size, "0");                 // (Python: ValueError - False)
        return 1;
    }
    size_t n = strlen(argv[1]);
    std::vector<unsigned char> sm(64 + n), m(64 + n);
    memcpy(sm.data(), sig.data(), 64);
    memcpy(sm.data() + 64, argv[1], n);
    unsigned long long mlen = 0;
    int bad = crypto_sign_ed25519_tweet_open(m.data(), &mlen, sm.data(), sm.size(), pk.data());
    snprintf(reply, size, "%s", bad ? "0" : "1");
    return 1;
}

int Random(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    int n = argc >= 1 ? atoi(argv[0]) : 0;
    if (n <= 0 || n > 512) return Fail(reply, size, "cj_random(n): 1 .. 512 bytes");
    std::vector<unsigned char> b(n);
    BCryptGenRandom(nullptr, b.data(), static_cast<ULONG>(n), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    snprintf(reply, size, "%s", Hex(b.data(), n).c_str());
    return 1;
}

int HmacSha256(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    std::vector<unsigned char> key;
    if (argc < 2 || !Unhex(argv[0], key)) return Fail(reply, size, "cj_hmac_sha256(key hex, message)");
    Hash h(&key);
    h.Add(argv[1], strlen(argv[1]));
    std::vector<unsigned char> d = h.Done();
    if (!h.ok) return Fail(reply, size, "cj_hmac_sha256: CNG failed");
    snprintf(reply, size, "%s", Hex(d.data(), d.size()).c_str());
    return 1;
}

int Sha256Parts(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    Hash h;
    for (int i = 0; i < argc; ++i) {
        const char* a = argv[i];
        if (a[0] == 't' && a[1] == ':') {
            h.Add(a + 2, strlen(a + 2));
        } else if (a[0] == 'z' && a[1] == 0) {
            unsigned char z = 0;
            h.Add(&z, 1);
        } else if (a[0] == 'x' && a[1] == ':') {
            std::vector<unsigned char> b;
            if (!Unhex(a + 2, b)) return Fail(reply, size, "cj_sha256_parts: not hex");
            h.Add(b.data(), b.size());
        } else if ((a[0] == 'f' || a[0] == 'F') && a[1] == ':') {
            std::vector<unsigned char> b;
            if (!ReadFile(a + 2, b)) return Fail(reply, size, std::string("cj_sha256_parts: cannot read ") + (a + 2));
            if (a[0] == 'F') {
                h.Add(b.data(), b.size());
            } else {
                Hash fh;
                fh.Add(b.data(), b.size());
                std::vector<unsigned char> d = fh.Done();
                h.Add(d.data(), d.size());
            }
        } else {
            return Fail(reply, size, "cj_sha256_parts: a part is t:, z, x:, f: or F:");
        }
    }
    std::vector<unsigned char> d = h.Done();
    if (!h.ok) return Fail(reply, size, "cj_sha256_parts: CNG failed");
    snprintf(reply, size, "%s", Hex(d.data(), d.size()).c_str());
    return 1;
}

}  // namespace crypto

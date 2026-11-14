/* TweetNaCl (public domain, deps/tweetnacl) with the one thing Conjunction needs beside it: an ed25519 key pair made
   from a given 32-byte seed (the private key the app keeps), the same steps as crypto_sign_keypair without its
   random seed. Its random bytes (for nothing here but the library's own keypair) come from Windows' CNG. */
#include <windows.h>
#include <bcrypt.h>
#include "deps/tweetnacl/tweetnacl.c"

void randombytes(u8* x, u64 n) {
    BCryptGenRandom(NULL, x, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
}

int cj_sign_seed_keypair(u8* pk, u8* sk, const u8* seed) {
    u8 d[64];
    gf p[4];
    int i;
    FOR(i, 32) sk[i] = seed[i];
    crypto_hash(d, sk, 32);
    d[0] &= 248;
    d[31] &= 127;
    d[31] |= 64;
    scalarbase(p, d);
    pack(pk, p);
    FOR(i, 32) sk[32 + i] = pk[i];
    return 0;
}

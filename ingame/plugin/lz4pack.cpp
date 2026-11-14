// cj_lz4hc_file(source, target) -> "<size> <stored size>": the source's bytes as one LZ4 block (python-lz4's
// lz4.block.compress(raw, mode="high_compression", store_size=False): a fresh HC stream at level 9, the bound as the
// room) written to target. Paths are UTF-8. Lua reads the block back with w3.fs.read (plugin arguments end at a 0 byte,
// so the bytes go through files).
#include "lz4pack.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdio>
#include <string>
#include <vector>

#include "deps/lz4/lz4.h"
#include "deps/lz4/lz4hc.h"

namespace lz4pack {
namespace {

int Fail(char* reply, uint32_t size, const std::string& s) {
    snprintf(reply, size, "%s", s.c_str());
    return 0;
}

std::wstring Wide(const char* s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

bool Read(const char* path, std::vector<char>& out) {
    FILE* f = _wfopen(Wide(path).c_str(), L"rb");
    if (!f) return false;
    _fseeki64(f, 0, SEEK_END);
    long long n = _ftelli64(f);
    _fseeki64(f, 0, SEEK_SET);
    out.resize(static_cast<size_t>(n));
    bool ok = n == 0 || fread(out.data(), 1, out.size(), f) == out.size();
    fclose(f);
    return ok;
}

bool Write(const char* path, const char* data, size_t n) {
    FILE* f = _wfopen(Wide(path).c_str(), L"wb");
    if (!f) return false;
    bool ok = n == 0 || fwrite(data, 1, n, f) == n;
    return fclose(f) == 0 && ok;
}

}  // namespace

int CompressFile(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_lz4hc_file(source, target)");
    std::vector<char> raw;
    if (!Read(argv[0], raw)) return Fail(reply, size, std::string("cj_lz4hc_file: cannot read ") + argv[0]);
    if (raw.size() > static_cast<size_t>(LZ4_MAX_INPUT_SIZE)) return Fail(reply, size, "cj_lz4hc_file: too big");
    int src = static_cast<int>(raw.size());
    int bound = LZ4_compressBound(src);
    std::vector<char> out(bound > 0 ? bound : 1);
    LZ4_streamHC_t* state = LZ4_createStreamHC();
    if (!state) return Fail(reply, size, "cj_lz4hc_file: no memory");
    LZ4_resetStreamHC(state, 9);
    int n = LZ4_compress_HC_continue(state, raw.data(), out.data(), src, bound);
    LZ4_freeStreamHC(state);
    if (n <= 0 && src > 0) return Fail(reply, size, "cj_lz4hc_file: compression failed");
    if (!Write(argv[1], out.data(), static_cast<size_t>(n))) {
        return Fail(reply, size, std::string("cj_lz4hc_file: cannot write ") + argv[1]);
    }
    snprintf(reply, size, "%d %d", src, n);
    return 1;
}

}  // namespace lz4pack

// The game's files straight out of its bundles (bundles.py): base game, expansions, DLCs, content packs and mods - no
// extraction step. A bundle: a header of 0x20 bytes (the TOC's size at 16), then per file 0x140 bytes (up to 4.04:
// name 0x100, hash 16, 0 u32, size, compressed size, offset, timestamp u64, 16 zero bytes, crc, compression) or
// 0x130 (the remaster: name, hash, offset u64, size, compressed size, crc, compression). Compression: 0 none, 1 zlib,
// 3 doboz, 4 / 5 lz4 (2, snappy: the game has none).
//
//   cj_depot_open(game)                  -> "files\tbundles"   the index (kept while no bundle changes)
//   cj_depot_exists(path)                -> "1" | "0"
//   cj_depot_read(path, out)             -> "size"            the file, unpacked, written to out
//   cj_depot_glob(prefix, suffix, out)   -> "count"           the paths (lower case) to out, one a line, in the
//                                                             index's order (Python's dict: first seen first)
//   cj_depot_open_async(game)            -> "busy" | "files\tbundles"   the index made on a thread of its own (the
//                                                             game's frame goes on); asked again until it is there
#include "depot.h"

#include "stb_image.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wctype.h>
#include <math.h>

#include <algorithm>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace depot {
namespace {

struct Entry {
    uint32_t bundle;
    uint64_t offset;
    uint32_t size, zsize, comp;
};

std::vector<std::wstring> g_bundles;
std::vector<std::string> g_order;                    // the paths in the order Python's dict has them
std::unordered_map<std::string, Entry> g_where;
std::wstring g_key;                                  // the game, each bundle, its time and size: read again on a change
std::mutex g_mx;                                     // (the index: made on the async thread, read on the game's)
bool g_building = false;

std::string Utf8(const std::wstring& w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], n, nullptr, nullptr);
    return s;
}
std::wstring Wide(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
    return w;
}
// str.lower for the depot's names (ASCII; the game's paths are)
std::string Lower(std::string s) {
    for (char& c : s) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    return s;
}
std::wstring LowerW(std::wstring s) {
    for (wchar_t& c : s) if (c >= L'A' && c <= L'Z') c = static_cast<wchar_t>(c - L'A' + L'a');
    return s;
}

// a folder's entries as os.scandir gives them (FindFirstFileW's order), directories or files, '.' names left out as
// glob does for '*'
std::vector<std::wstring> List(const std::wstring& dir, bool dirs) {
    std::vector<std::wstring> out;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return out;
    do {
        std::wstring n = fd.cFileName;
        if (n.empty() || n[0] == L'.') continue;
        bool is_dir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (is_dir == dirs) out.push_back(n);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return out;
}
bool IsDir(const std::wstring& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}
bool StartsI(const std::wstring& s, const wchar_t* pre) {
    size_t n = wcslen(pre);
    return s.size() >= n && LowerW(s.substr(0, n)) == LowerW(pre);
}
bool EndsI(const std::wstring& s, const wchar_t* suf) {
    size_t n = wcslen(suf);
    return s.size() >= n && LowerW(s.substr(s.size() - n)) == LowerW(suf);
}
// the *.bundle files of a folder
void Bundles(const std::wstring& dir, std::vector<std::wstring>& out) {
    if (!IsDir(dir)) return;
    for (const auto& f : List(dir, false)) if (EndsI(f, L".bundle")) out.push_back(dir + L"\\" + f);
}

// bundles.bundle_paths: the same globs in the same order
std::vector<std::wstring> BundlePaths(const std::wstring& game) {
    std::vector<std::wstring> out;
    for (const auto& d : List(game + L"\\content", true))
        if (StartsI(d, L"content")) Bundles(game + L"\\content\\" + d + L"\\bundles", out);
    for (const auto& d : List(game + L"\\dlc", true)) Bundles(game + L"\\dlc\\" + d + L"\\content\\bundles", out);
    // DLCs and mods as REDkit / wcc_lite pack them (content\blob0.bundle): content packs, Conjunction's own DLCs
    for (const auto& d : List(game + L"\\dlc", true)) Bundles(game + L"\\dlc\\" + d + L"\\content", out);
    // (not a project's own: Mods\moddlc<id> holds the game's files a project changed)
    for (const auto& d : List(game + L"\\Mods", true))
        if (!StartsI(d, L"moddlc")) Bundles(game + L"\\Mods\\" + d + L"\\content", out);
    return out;
}

const uint32_t ENTRY = 0x140, ENTRY_V5 = 0x130;
bool IsAlnum(unsigned char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
// 0x140 or 0x130 a file (bundles._entry_size): the second entry's name starts right after the first one
uint32_t EntrySize(const std::vector<unsigned char>& toc) {
    size_t n = toc.size();
    if (n % ENTRY && n % ENTRY_V5 == 0) return ENTRY_V5;
    if (n >= 2 * ENTRY_V5 && n % ENTRY_V5 == 0) {
        auto starts = [&](size_t at) { return at < n && IsAlnum(toc[at]) && toc[at - 1] == 0; };
        if (starts(ENTRY_V5) && (n % ENTRY || !starts(ENTRY))) return ENTRY_V5;
    }
    return ENTRY;
}
uint32_t U32(const unsigned char* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24); }
uint64_t U64(const unsigned char* p) { return U32(p) | (uint64_t(U32(p + 4)) << 32); }

// one bundle's files into an index (bundles, order, where: the ones being made)
void Index(uint32_t b, const std::vector<std::wstring>& bundles, std::vector<std::string>& order,
           std::unordered_map<std::string, Entry>& where) {
    FILE* f = _wfopen(bundles[b].c_str(), L"rb");
    if (!f) return;
    unsigned char head[0x20];
    if (fread(head, 1, 0x20, f) != 0x20) { fclose(f); return; }
    uint32_t n = U32(head + 16);
    std::vector<unsigned char> toc(n);
    size_t got = n ? fread(toc.data(), 1, n, f) : 0;
    fclose(f);
    toc.resize(got);
    uint32_t step = EntrySize(toc);
    for (size_t i = 0; i + step <= toc.size(); i += step) {
        const unsigned char* o = toc.data() + i;
        size_t len = 0;
        while (len < 0x100 && o[len]) ++len;
        std::string name = Lower(std::string(reinterpret_cast<const char*>(o), len));
        Entry e{b, 0, 0, 0, 0};
        if (step == ENTRY_V5) {
            e.offset = U64(o + 0x110);
            e.size = U32(o + 0x118);
            e.zsize = U32(o + 0x11C);
            e.comp = U32(o + 0x124);
        } else {
            e.size = U32(o + 0x114);
            e.zsize = U32(o + 0x118);
            e.offset = U32(o + 0x11C);
            e.comp = U32(o + 0x13C);
        }
        auto it = where.find(name);
        if (it == where.end()) {
            order.push_back(name);
            where.emplace(name, e);
        } else {
            it->second = e;                           // (a later bundle wins; the path keeps its place)
        }
    }
}

// Doboz (Attila T. Afra): a header (attributes: the size field's width, stored), then 32-bit control words - bit 0 a
// literal byte, 1 a match (offset back, length >= 3) - bundles.doboz_decompress
struct DobozCode { uint32_t mask, oshift, lmask, lshift, n; };
const DobozCode DOBOZ[8] = {{0xFF, 2, 0, 0, 1}, {0xFFFF, 2, 0, 0, 2}, {0xFFFF, 6, 15, 2, 2}, {0xFFFFFF, 8, 31, 3, 3},
                            {0xFF, 2, 0, 0, 1}, {0xFFFF, 2, 0, 0, 2}, {0xFFFF, 6, 15, 2, 2},
                            {0xFFFFFFFF, 11, 255, 3, 4}};
bool Doboz(const std::vector<unsigned char>& in, uint32_t size, std::vector<unsigned char>& out) {
    if (in.empty()) return false;
    unsigned char attrs = in[0];
    size_t size_bytes = ((attrs >> 3) & 7) + 1;
    size_t pos = 1 + 2 * size_bytes;
    if (attrs & 0x80) {
        if (pos > in.size()) return false;
        out.assign(in.begin() + pos, in.begin() + (std::min)(in.size(), pos + size));
        return true;
    }
    std::vector<unsigned char> src(in);
    src.resize(src.size() + 8, 0);
    out.clear();
    out.reserve(size);
    uint32_t control = 1;
    while (out.size() < size) {
        if (control == 1) {
            if (pos + 4 > src.size()) return false;
            control = U32(&src[pos]);
            pos += 4;
        }
        if (control & 1) {
            if (pos + 4 > src.size()) return false;
            uint32_t w = U32(&src[pos]);
            const DobozCode& c = DOBOZ[w & 7];
            uint32_t offset = (w & c.mask) >> c.oshift;
            uint32_t length = ((w >> c.lshift) & c.lmask) + 3;
            pos += c.n;
            if (offset > out.size()) return false;
            size_t start = out.size() - offset;
            for (uint32_t k = 0; k < length; ++k) out.push_back(out[start + k]);
        } else {
            if (pos >= src.size()) return false;
            out.push_back(src[pos++]);
        }
        control >>= 1;
    }
    out.resize(size);
    return true;
}

// an LZ4 block (lz4.block.decompress with its size given)
bool Lz4(const std::vector<unsigned char>& in, uint32_t size, std::vector<unsigned char>& out) {
    out.clear();
    out.reserve(size);
    size_t i = 0, n = in.size();
    while (i < n) {
        unsigned char tok = in[i++];
        size_t lit = tok >> 4;
        if (lit == 15) {
            unsigned char b;
            do {
                if (i >= n) return false;
                b = in[i++];
                lit += b;
            } while (b == 255);
        }
        if (i + lit > n) return false;
        out.insert(out.end(), in.begin() + i, in.begin() + i + lit);
        i += lit;
        if (i >= n) break;                            // (the last literals end the block)
        if (i + 2 > n) return false;
        size_t off = in[i] | (in[i + 1] << 8);
        i += 2;
        if (off == 0 || off > out.size()) return false;
        size_t ml = tok & 15;
        if (ml == 15) {
            unsigned char b;
            do {
                if (i >= n) return false;
                b = in[i++];
                ml += b;
            } while (b == 255);
        }
        ml += 4;
        size_t start = out.size() - off;
        for (size_t k = 0; k < ml; ++k) out.push_back(out[start + k]);
    }
    return out.size() == size;
}

// the game's own bundles stay open (25.10.: opening one for each file was most of a read - the asset build read
// 23 000 templates); Conjunction's and other mods' DLCs are opened each time (a build writes them again)
std::mutex g_open_mx;
std::unordered_map<std::wstring, HANDLE> g_open;
bool GamesOwn(const std::wstring& bundle) {
    std::wstring low = bundle;
    for (auto& c : low) c = towlower(c);
    size_t d = low.find(L"\\dlc\\");
    if (d == std::wstring::npos) return low.find(L"\\content\\content") != std::wstring::npos;
    size_t e = low.find(L'\\', d + 5);
    if (e == std::wstring::npos) return false;
    std::wstring name = low.substr(d + 5, e - d - 5);
    if (name == L"ep1" || name == L"bob") return true;
    if (name.size() < 4 || name.compare(0, 3, L"dlc") != 0) return false;
    for (size_t i = 3; i < name.size(); ++i) if (!iswdigit(name[i])) return false;
    return true;
}
// zsize bytes at offset (a positional read: several threads may read one open bundle) -> how many
bool ReadBytes(const std::wstring& bundle, uint64_t offset, std::vector<unsigned char>& data) {
    bool keep = GamesOwn(bundle);
    HANDLE h = INVALID_HANDLE_VALUE;
    if (keep) {
        std::lock_guard<std::mutex> lk(g_open_mx);
        auto it = g_open.find(bundle);
        if (it != g_open.end()) h = it->second;
    }
    if (h == INVALID_HANDLE_VALUE) {
        h = CreateFileW(bundle.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE) return false;
        if (keep) {
            std::lock_guard<std::mutex> lk(g_open_mx);
            auto it = g_open.find(bundle);
            if (it != g_open.end()) { CloseHandle(h); h = it->second; }
            else g_open[bundle] = h;
        }
    }
    size_t got = 0;
    while (got < data.size()) {
        OVERLAPPED ov = {};
        uint64_t at = offset + got;
        ov.Offset = static_cast<DWORD>(at & 0xffffffffu);
        ov.OffsetHigh = static_cast<DWORD>(at >> 32);
        DWORD n = 0, want = static_cast<DWORD>((std::min)(data.size() - got, static_cast<size_t>(1u << 30)));
        if (!ReadFile(h, data.data() + got, want, &n, &ov) || n == 0) break;
        got += n;
    }
    if (!keep) CloseHandle(h);
    data.resize(got);
    return true;
}

bool ReadAt(const std::wstring& bundle, const Entry& e, std::vector<unsigned char>& out, std::string& err) {
    std::vector<unsigned char> data(e.zsize);
    if (!ReadBytes(bundle, e.offset, data)) { err = "cannot open its bundle"; return false; }
    switch (e.comp) {
    case 0:
        data.resize((std::min)(data.size(), static_cast<size_t>(e.size)));
        out.swap(data);
        return true;
    case 1: {
        int len = 0;
        char* z = stbi_zlib_decode_malloc_guesssize(reinterpret_cast<const char*>(data.data()),
                                                    static_cast<int>(data.size()), static_cast<int>(e.size) + 1, &len);
        if (!z) { err = "zlib: broken"; return false; }
        out.assign(z, z + len);
        free(z);
        return true;
    }
    case 3:
        if (!Doboz(data, e.size, out)) { err = "doboz: broken"; return false; }
        return true;
    case 4:
    case 5:
        if (!Lz4(data, e.size, out)) { err = "lz4: broken"; return false; }
        return true;
    }
    err = "compression " + std::to_string(e.comp) + " not supported";
    return false;
}

bool Read(const Entry& e, std::vector<unsigned char>& out, std::string& err) {
    return ReadAt(g_bundles[e.bundle], e, out, err);
}

int Fail(char* reply, uint32_t size, const std::string& s) {
    snprintf(reply, size, "%s", s.c_str());
    return 0;
}
bool WriteFile(const std::string& path, const void* data, size_t n) {
    std::wstring tmp = Wide(path + ".tmp");
    FILE* o = _wfopen(tmp.c_str(), L"wb");
    if (!o) return false;
    size_t wrote = n ? fwrite(data, 1, n, o) : 0;
    fclose(o);
    if (wrote != n) { DeleteFileW(tmp.c_str()); return false; }
    if (!MoveFileExW(tmp.c_str(), Wide(path).c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(tmp.c_str());
        return false;
    }
    return true;
}

}  // namespace

// the index for this game (made again only when a bundle changed)
void Build(std::wstring game) {
    while (!game.empty() && (game.back() == L'\\' || game.back() == L'/')) game.pop_back();
    std::vector<std::wstring> paths = BundlePaths(game);
    std::wstring key = game;
    for (const auto& p : paths) {
        WIN32_FILE_ATTRIBUTE_DATA a;
        if (!GetFileAttributesExW(p.c_str(), GetFileExInfoStandard, &a)) continue;
        wchar_t buf[96];
        swprintf(buf, 96, L"|%u.%u.%u.%u", a.ftLastWriteTime.dwHighDateTime, a.ftLastWriteTime.dwLowDateTime,
                 a.nFileSizeHigh, a.nFileSizeLow);
        key += L"\n" + p + buf;
    }
    {
        std::lock_guard<std::mutex> lk(g_mx);
        if (key == g_key) return;
    }
    // (made apart, then put in place: a lookup meanwhile waits only for the swap)
    std::vector<std::string> order;
    std::unordered_map<std::string, Entry> where;
    for (uint32_t b = 0; b < paths.size(); ++b) Index(b, paths, order, where);
    std::lock_guard<std::mutex> lk(g_mx);
    g_bundles.swap(paths);
    g_order.swap(order);
    g_where.swap(where);
    g_key = key;
}

int Open(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_depot_open(game)");
    {
        std::lock_guard<std::mutex> lk(g_mx);
        if (g_building) return Fail(reply, size, "cj_depot_open: the index is being made (cj_depot_open_async)");
    }
    Build(Wide(argv[0]));
    std::lock_guard<std::mutex> lk(g_mx);
    snprintf(reply, size, "%zu\t%zu", g_order.size(), g_bundles.size());
    return 1;
}

int OpenAsync(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_depot_open_async(game)");
    std::lock_guard<std::mutex> lk(g_mx);
    if (g_building) {
        snprintf(reply, size, "busy");
        return 1;
    }
    if (!g_key.empty() && g_key.compare(0, Wide(argv[0]).size(), Wide(argv[0])) == 0 && !g_order.empty()) {
        snprintf(reply, size, "%zu\t%zu", g_order.size(), g_bundles.size());   // (made before: the bundles as then)
        return 1;
    }
    g_building = true;
    std::thread([game = Wide(argv[0])] {
        Build(game);
        std::lock_guard<std::mutex> l2(g_mx);
        g_building = false;
    }).detach();
    snprintf(reply, size, "busy");
    return 1;
}

int Exists(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_depot_exists(path)");
    std::lock_guard<std::mutex> lk(g_mx);
    snprintf(reply, size, "%s", g_where.count(Lower(argv[0])) ? "1" : "0");
    return 1;
}

int (*g_reply_bytes)(const void* data, size_t size) = nullptr;

// cj_depot_data(path) -> the file's bytes as Lua's string (no file between: TW3SE's LuaReplyBytes)
int Data(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_depot_data(path)");
    if (!g_reply_bytes) return Fail(reply, size, "cj_depot_data: TW3SE has no LuaReplyBytes (interface 20)");
    Entry e;
    {
        std::lock_guard<std::mutex> lk(g_mx);
        auto it = g_where.find(Lower(argv[0]));
        if (it == g_where.end()) return Fail(reply, size, std::string("cj_depot_data: not in the game: ") + argv[0]);
        e = it->second;
    }
    std::vector<unsigned char> out;
    std::string err;
    if (!Read(e, out, err)) return Fail(reply, size, std::string("cj_depot_data: ") + argv[0] + ": " + err);
    g_reply_bytes(out.data(), out.size());
    return 1;
}

// cj_mesh_rows(buffer, s0, s1, s2, nverts, stride, start, nidx, scale x y z, offset x y z [, the place: position
// x y z, roll pitch yaw, scale x y z]) -> bytes: lowest x y z, highest x y z (6 doubles, zeros without a triangle),
// the count of floats (u32), the floats - a render chunk of a mesh as meshview.read_mesh made its rows in Lua
// (8 a corner: position, uv, normal; each triangle's corners one after the other), moved by place() when a place
// is given. Every number is worked out in doubles in Lua's order, so the floats are the bytes string.pack("f") wrote
// from Lua's numbers, the bounds those frame_of saw. 12.11.: in Lua a person's look took 100-400 ms of the frame
// (sliced at 4 ms a frame: up to 2 s a look tile), here a few ms.
int MeshRows(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 14) return Fail(reply, size, "cj_mesh_rows(buffer, s0, s1, s2, nverts, stride, start, nidx, sx sy sz, ox oy oz [, place])");
    if (!g_reply_bytes) return Fail(reply, size, "cj_mesh_rows: TW3SE has no LuaReplyBytes (interface 20)");
    static std::string s_path;                      // (one mesh's render chunks come one after the other: its buffer
    static std::vector<unsigned char> s_buf;        // read once)
    std::string path = Lower(argv[0]);
    if (path != s_path) {
        Entry e;
        {
            std::lock_guard<std::mutex> lk(g_mx);
            auto it = g_where.find(path);
            if (it == g_where.end()) return Fail(reply, size, std::string("cj_mesh_rows: not in the game: ") + argv[0]);
            e = it->second;
        }
        std::string err;
        s_path.clear();
        if (!Read(e, s_buf, err)) return Fail(reply, size, std::string("cj_mesh_rows: ") + argv[0] + ": " + err);
        s_path = path;
    }
    const std::vector<unsigned char>& buf = s_buf;
    const int64_t n = static_cast<int64_t>(buf.size());
    const int64_t s0 = _atoi64(argv[1]), s1 = _atoi64(argv[2]), s2 = _atoi64(argv[3]);
    const int64_t nverts = _atoi64(argv[4]), stride = _atoi64(argv[5]), start = _atoi64(argv[6]), nidx = _atoi64(argv[7]);
    double sc[3], of[3];
    for (int k = 0; k < 3; ++k) {
        sc[k] = strtod(argv[8 + k], nullptr);
        of[k] = strtod(argv[11 + k], nullptr);
    }
    auto u16 = [&](int64_t at) { return static_cast<uint32_t>(buf[at] | (buf[at + 1] << 8)); };
    if (s0 < 0 || nverts < 0 || s0 + stride * nverts > n) return Fail(reply, size, "cj_mesh_rows: the positions past the buffer");
    std::vector<double> px(nverts), py(nverts), pz(nverts);
    for (int64_t i = 0; i < nverts; ++i) {
        int64_t at = s0 + stride * i;
        px[i] = u16(at) / 65535.0 * sc[0] + of[0];
        py[i] = u16(at + 2) / 65535.0 * sc[1] + of[1];
        pz[i] = u16(at + 4) / 65535.0 * sc[2] + of[2];
    }
    int64_t uvlen = (std::max)(int64_t(0), (std::min)(4 * nverts, n - s1));
    if (uvlen % 4) return Fail(reply, size, "cj_mesh_rows: a broken uv stream");
    const int64_t nuv = uvlen / 4;
    auto half = [](uint32_t h) {                    // (meshview.half: Python's struct "e")
        double sign = (h & 0x8000) ? -1.0 : 1.0;
        uint32_t e = (h >> 10) & 0x1f, m = h & 0x3ff;
        if (e == 0) return sign * m * ldexp(1.0, -24);
        if (e == 31) return m == 0 ? sign * HUGE_VAL : std::numeric_limits<double>::quiet_NaN();
        return sign * (1.0 + m / 1024.0) * ldexp(1.0, static_cast<int>(e) - 15);
    };
    std::vector<double> uu(nuv), uw(nuv);
    for (int64_t i = 0; i < nuv; ++i) {
        uu[i] = half(u16(s1 + 4 * i));
        uw[i] = half(u16(s1 + 4 * i + 2));
    }
    const bool normals = s2 != 0 && s2 + 8 * nverts <= n;
    std::vector<double> nx0, ny0, nz0;
    if (normals) {
        nx0.resize(nverts), ny0.resize(nverts), nz0.resize(nverts);
        for (int64_t i = 0; i < nverts; ++i) {
            int64_t at = s2 + 8 * i;
            uint32_t w = buf[at] | (buf[at + 1] << 8) | (buf[at + 2] << 16) | (static_cast<uint32_t>(buf[at + 3]) << 24);
            nx0[i] = ((w & 1023) / 511.5) - 1.0;
            ny0[i] = (((w >> 10) & 1023) / 511.5) - 1.0;
            nz0[i] = (((w >> 20) & 1023) / 511.5) - 1.0;
        }
    }
    if (start + 2 * nidx > n) return Fail(reply, size, "cj_mesh_rows: the indices past the buffer");
    // the place (meshview.place): scale, roll around y, pitch around x, yaw around z, then the position
    const bool placed = argc >= 23;
    double pp[3] = {0, 0, 0}, sx = 1, sy = 1, sz = 1, cr = 1, sr = 0, cp = 1, sp = 0, cy = 1, syw = 0;
    bool moves = false;
    if (placed) {
        double v[9];
        for (int k = 0; k < 9; ++k) v[k] = strtod(argv[14 + k], nullptr);
        pp[0] = v[0], pp[1] = v[1], pp[2] = v[2];
        double roll = v[3], pitch = v[4], yaw = v[5];
        sx = v[6], sy = v[7], sz = v[8];
        moves = !(pp[0] == 0 && pp[1] == 0 && pp[2] == 0 && pitch == 0 && yaw == 0 && roll == 0 && sx == 1 && sy == 1 && sz == 1);
        const double R = 3.141592653589793 / 180.0;   // (Lua's math.rad: x * (PI / 180))
        cy = cos(yaw * R), syw = sin(yaw * R);
        cp = cos(pitch * R), sp = sin(pitch * R);
        cr = cos(roll * R), sr = sin(roll * R);
    }
    auto turn = [&](double& x, double& y, double& z) {
        double x1 = x * cr + z * sr, z1 = -x * sr + z * cr;
        double y2 = y * cp - z1 * sp, z2 = y * sp + z1 * cp;
        double x3 = x1 * cy - y2 * syw, y3 = x1 * syw + y2 * cy;
        x = x3, y = y3, z = z2;
    };
    std::vector<unsigned char> out(52);
    std::vector<float> rows;
    rows.reserve(static_cast<size_t>(nidx) * 8);
    double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    bool any = false;
    for (int64_t t = 0; t <= nidx - 3; t += 3) {
        uint32_t a = u16(start + 2 * t), b = u16(start + 2 * t + 2), c = u16(start + 2 * t + 4);
        if (!(a < nverts && b < nverts && c < nverts)) continue;
        double ax = px[a], ay = py[a], az = pz[a];
        double ux = px[b] - ax, uy = py[b] - ay, uz = pz[b] - az;
        double vx = px[c] - ax, vy = py[c] - ay, vz = pz[c] - az;
        double fx = uy * vz - uz * vy, fy = uz * vx - ux * vz, fz = ux * vy - uy * vx;
        double ln = sqrt(fx * fx + fy * fy + fz * fz);
        if (ln == 0) ln = 1.0;
        fx = -fx / ln, fy = -fy / ln, fz = -fz / ln;
        for (uint32_t v : {a, b, c}) {
            if (v >= nuv) return Fail(reply, size, "cj_mesh_rows: a vertex without its uv");
            double x = px[v], y = py[v], z = pz[v];
            double ex = normals ? nx0[v] : fx, ey = normals ? ny0[v] : fy, ez = normals ? nz0[v] : fz;
            if (moves) {
                x *= sx, y *= sy, z *= sz;
                turn(x, y, z);
                x += pp[0], y += pp[1], z += pp[2];
                turn(ex, ey, ez);
            }
            double p3[3] = {x, y, z};
            for (int k = 0; k < 3; ++k) {
                if (!any) lo[k] = hi[k] = p3[k];
                if (p3[k] < lo[k]) lo[k] = p3[k];
                if (p3[k] > hi[k]) hi[k] = p3[k];
            }
            any = true;
            float r[8] = {static_cast<float>(x), static_cast<float>(y), static_cast<float>(z), static_cast<float>(uu[v]),
                          static_cast<float>(uw[v]), static_cast<float>(ex), static_cast<float>(ey), static_cast<float>(ez)};
            rows.insert(rows.end(), r, r + 8);
        }
    }
    memcpy(out.data(), lo, 24);
    memcpy(out.data() + 24, hi, 24);
    uint32_t count = static_cast<uint32_t>(rows.size());
    memcpy(out.data() + 48, &count, 4);
    out.resize(52 + rows.size() * 4);
    if (!rows.empty()) memcpy(out.data() + 52, rows.data(), rows.size() * 4);
    g_reply_bytes(out.data(), out.size());
    return 1;
}

int ReadTo(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_depot_read(path, out)");
    Entry e;
    {
        std::lock_guard<std::mutex> lk(g_mx);
        auto it = g_where.find(Lower(argv[0]));
        if (it == g_where.end()) return Fail(reply, size, std::string("cj_depot_read: not in the game: ") + argv[0]);
        e = it->second;
    }
    std::vector<unsigned char> out;
    std::string err;
    if (!Read(e, out, err)) return Fail(reply, size, std::string("cj_depot_read: ") + argv[0] + ": " + err);
    if (!WriteFile(argv[1], out.data(), out.size()))
        return Fail(reply, size, std::string("cj_depot_read: cannot write ") + argv[1]);
    snprintf(reply, size, "%zu", out.size());
    return 1;
}

// cj_bundle_read(bundle, offset, size, stored size, compression, out) -> its size: one file of any bundle (a mod's,
// packaging's checks) as bundles.read gives it
int BundleRead(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 6) return Fail(reply, size, "cj_bundle_read(bundle, offset, size, zsize, comp, out)");
    Entry e;
    e.bundle = 0;
    e.offset = _strtoui64(argv[1], nullptr, 10);
    e.size = static_cast<uint32_t>(strtoul(argv[2], nullptr, 10));
    e.zsize = static_cast<uint32_t>(strtoul(argv[3], nullptr, 10));
    e.comp = static_cast<uint32_t>(strtoul(argv[4], nullptr, 10));
    std::vector<unsigned char> out;
    std::string err;
    if (!ReadAt(Wide(argv[0]), e, out, err)) return Fail(reply, size, std::string("cj_bundle_read: ") + err);
    if (!WriteFile(argv[5], out.data(), out.size()))
        return Fail(reply, size, std::string("cj_bundle_read: cannot write ") + argv[5]);
    snprintf(reply, size, "%zu", out.size());
    return 1;
}

int Glob(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 3) return Fail(reply, size, "cj_depot_glob(prefix, suffix, out)");
    std::string pre = Lower(argv[0]), suf = Lower(argv[1]);
    std::string out;
    size_t n = 0;
    std::lock_guard<std::mutex> lk(g_mx);
    for (const auto& p : g_order) {
        if (p.compare(0, pre.size(), pre) == 0 && p.size() >= suf.size() &&
            p.compare(p.size() - suf.size(), suf.size(), suf) == 0) {
            out += p;
            out += '\n';
            ++n;
        }
    }
    if (!WriteFile(argv[2], out.data(), out.size()))
        return Fail(reply, size, std::string("cj_depot_glob: cannot write ") + argv[2]);
    snprintf(reply, size, "%zu", n);
    return 1;
}

// as Glob, each path with the bundle it comes from (bundles.Depot.where[p][0]: the asset database keeps the game's
// own and the DLCs', 20.10.) - "path<tab>bundle" a line
int GlobWhere(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 3) return Fail(reply, size, "cj_depot_glob_where(prefix, suffix, out)");
    std::string pre = Lower(argv[0]), suf = Lower(argv[1]);
    std::string out;
    size_t n = 0;
    std::lock_guard<std::mutex> lk(g_mx);
    for (const auto& p : g_order) {
        if (p.compare(0, pre.size(), pre) == 0 && p.size() >= suf.size() &&
            p.compare(p.size() - suf.size(), suf.size(), suf) == 0) {
            auto it = g_where.find(p);
            out += p;
            out += '\t';
            if (it != g_where.end() && it->second.bundle < g_bundles.size()) out += Utf8(g_bundles[it->second.bundle]);
            out += '\n';
            ++n;
        }
    }
    if (!WriteFile(argv[2], out.data(), out.size()))
        return Fail(reply, size, std::string("cj_depot_glob_where: cannot write ") + argv[2]);
    snprintf(reply, size, "%zu", n);
    return 1;
}

}  // namespace depot

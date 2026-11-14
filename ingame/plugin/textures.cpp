// Pictures out of the game's texture.cache files (textures.TextureCache): item icons, the textures of a mesh.
// Footer (last 32 bytes): crc u64, used pages, entry count, string table size, mip table count, "HCXT", version.
// Before it the entries (52 bytes: hash, name offset, page (x 4096), packed size, size, alignment, width, height,
// mips, slices, mip offset index, mip count, timestamp, type1, type2, cube, -), the names before them. An entry's
// data: one piece per mip (packed size u32, size u32, mip u8, zlib). type1: 7 DXT1, 8 DXT5, 13 DXT3, 10 BC7, 14 BC4,
// 15 BC5, else uncompressed BGRA. Decoded with Pillow's own block decoders (bcn_pillow.h): the app's pixels.
//
//   cj_tex_open(game)                      -> "textures\tfiles"
//   cj_tex_image(name, max_side, out.png)  -> "w\th"     the top mip (max_side > 0: the first not bigger than that)
//   cj_tex_decode(type1, w, h, in, out)    -> "bytes"    raw blocks to raw RGBA (for ref/textures_check.py)
//   cj_tex_image_async(name, max_side, out) -> "queued"  the same on cj_core's own thread (the game's frame goes on)
//   cj_tex_status(out)                     -> "busy" | "w\th" | "!why"   (once done, the answer is given once)
// The PNGs are written with zlib's level 1: the same pixels, made several times faster (a 512 px texture: 100 ms
// at stb's default 8).
#include "textures.h"

#include "bcn_pillow.h"
#include "stb_image.h"
#include "stb_image_write.h"

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace textures {
namespace {

struct Entry {
    uint32_t file;
    uint32_t page, zsize, usize;
    uint16_t w, h;
    uint8_t t1;
};
std::vector<std::wstring> g_files;
std::unordered_map<std::string, Entry> g_index;
std::wstring g_game;
std::mutex g_index_mx;              // (the index: built on the game's thread, looked up on the worker's too)

std::wstring Wide(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
    return w;
}
std::string Lower(std::string s) {
    for (char& c : s) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    return s;
}
std::wstring LowerW(std::wstring s) {
    for (wchar_t& c : s) if (c >= L'A' && c <= L'Z') c = static_cast<wchar_t>(c - L'A' + L'a');
    return s;
}
uint32_t U32(const unsigned char* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24); }
uint16_t U16(const unsigned char* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }

std::vector<std::wstring> Dirs(const std::wstring& dir) {
    std::vector<std::wstring> out;
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return out;
    do {
        std::wstring n = fd.cFileName;
        if (!n.empty() && n[0] != L'.' && (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) out.push_back(n);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return out;
}
bool IsFile(const std::wstring& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

void ReadIndex(uint32_t k) {
    FILE* f = _wfopen(g_files[k].c_str(), L"rb");
    if (!f) return;
    _fseeki64(f, 0, SEEK_END);
    long long size = _ftelli64(f);
    if (size < 32) { fclose(f); return; }
    unsigned char foot[32];
    _fseeki64(f, size - 32, SEEK_SET);
    if (fread(foot, 1, 32, f) != 32) { fclose(f); return; }
    uint32_t count = U32(foot + 12), strsize = U32(foot + 16), ident = U32(foot + 24);
    if (ident != 0x54584348) { fclose(f); return; }   // "HCXT"
    long long entries = size - 32 - static_cast<long long>(count) * 52;
    if (entries - strsize < 0) { fclose(f); return; }
    std::vector<unsigned char> table(strsize), raw(static_cast<size_t>(count) * 52);
    _fseeki64(f, entries - strsize, SEEK_SET);
    size_t got_t = strsize ? fread(table.data(), 1, strsize, f) : 0;
    _fseeki64(f, entries, SEEK_SET);
    size_t got_r = raw.empty() ? 0 : fread(raw.data(), 1, raw.size(), f);
    fclose(f);
    if (got_t != strsize || got_r != raw.size()) return;   // (struct.error in Python: this file is left out)
    // (each entry goes in as it is read: one that raises in Python ends the file, the ones before it stay)
    for (uint32_t i = 0; i < count; ++i) {
        const unsigned char* e = raw.data() + static_cast<size_t>(i) * 52;
        int32_t o = static_cast<int32_t>(U32(e + 4));
        if (o < 0 || static_cast<uint32_t>(o) >= strsize) return;   // (table.index raises)
        size_t z = o;
        while (z < strsize && table[z]) ++z;
        if (z >= strsize) return;
        std::string name = Lower(std::string(reinterpret_cast<const char*>(&table[o]), z - o));
        Entry en{k, U32(e + 8), U32(e + 12), U32(e + 16), U16(e + 24), U16(e + 26), e[48]};
        g_index[name] = en;
    }
}

// Pillow's DDS decoding of w x h: N its decoder (1 DXT1 ... 7 BC7), channels 1 (L), 3 (RGB) or 4; -> RGBA
bool DecodeBlocks(int n, int w, int h, const unsigned char* src, size_t bytes, std::vector<unsigned char>& rgba_out) {
    int bw = (std::max)(1, (w + 3) / 4), bh = (std::max)(1, (h + 3) / 4);
    size_t bsize = (n == 1 || n == 4) ? 8 : 16;
    if (bytes < static_cast<size_t>(bw) * bh * bsize) return false;   // (PIL: the picture is truncated)
    rgba_out.assign(static_cast<size_t>(w) * h * 4, 0);
    const unsigned char* p = src;
    for (int by = 0; by < bh; ++by) {
        for (int bx = 0; bx < bw; ++bx, p += bsize) {
            rgba col[16];
            lum lc[16];
            memset(col, 0, sizeof col);
            memset(lc, 0, sizeof lc);
            switch (n) {
            case 1: decode_bc1_block(col, p); break;
            case 2: decode_bc2_block(col, p); break;
            case 3: decode_bc3_block(col, p); break;
            case 4: decode_bc4_block(lc, p); break;
            case 5: decode_bc5_block(col, p, 0); break;
            case 7: decode_bc7_block(col, p); break;
            }
            for (int j = 0; j < 4; ++j) {
                int y = by * 4 + j;
                if (y >= h) continue;
                for (int i = 0; i < 4; ++i) {
                    int x = bx * 4 + i;
                    if (x >= w) continue;
                    unsigned char* d = &rgba_out[(static_cast<size_t>(y) * w + x) * 4];
                    const rgba& c = col[j * 4 + i];
                    if (n == 4) {                         // mode L -> RGBA
                        d[0] = d[1] = d[2] = lc[j * 4 + i].l;
                        d[3] = 255;
                    } else if (n == 5) {                  // mode RGB -> RGBA
                        d[0] = c.r; d[1] = c.g; d[2] = c.b; d[3] = 255;
                    } else {
                        d[0] = c.r; d[1] = c.g; d[2] = c.b; d[3] = c.a;
                    }
                }
            }
        }
    }
    return true;
}
int Decoder(uint8_t t1) {
    switch (t1) {
    case 7: return 1;   // DXT1
    case 13: return 2;  // DXT3
    case 8: return 3;   // DXT5
    case 14: return 4;  // ATI1 (BC4)
    case 15: return 5;  // ATI2 (BC5)
    case 10: return 7;  // BC7 (DX10, DXGI 98)
    }
    return 0;
}

int Fail(char* reply, uint32_t size, const std::string& s) {
    snprintf(reply, size, "%s", s.c_str());
    return 0;
}

bool WriteAll(const std::string& path, const void* data, size_t n);

// cj_tex_image's work: "" and the size, or why not ("none": not in the caches or not a picture)
std::string MakeImage(const std::string& name, int max_side, const std::string& out_path, int* ow, int* oh) {
    Entry e;
    std::wstring file;
    {
        std::lock_guard<std::mutex> lk(g_index_mx);
        auto it = g_index.find(Lower(name));
        if (it == g_index.end()) return "none";
        e = it->second;
        file = g_files[e.file];
    }
    FILE* f = _wfopen(file.c_str(), L"rb");
    if (!f) return "cj_tex_image: cannot open the cache";
    std::vector<unsigned char> raw(static_cast<size_t>(e.zsize) + 64);
    _fseeki64(f, static_cast<long long>(e.page) * 4096, SEEK_SET);
    raw.resize(fread(raw.data(), 1, raw.size(), f));
    fclose(f);
    std::vector<std::vector<unsigned char>> pieces;
    std::vector<unsigned char> data;
    size_t i = 0;
    while (i + 9 <= raw.size() && data.size() < e.usize) {
        uint32_t psize = U32(&raw[i]), usz = U32(&raw[i + 4]);
        if (psize == 0 || usz == 0) break;
        size_t take = (std::min)(static_cast<size_t>(psize), raw.size() - (i + 9));
        int len = 0;
        char* z = stbi_zlib_decode_malloc_guesssize(reinterpret_cast<const char*>(&raw[i + 9]), static_cast<int>(take),
                                                    static_cast<int>(usz) + 1, &len);
        if (!z) return "cj_tex_image: a broken piece";
        pieces.emplace_back(z, z + len);
        data.insert(data.end(), z, z + len);
        free(z);
        i += 9 + psize;
    }
    int w = e.w, h = e.h;
    int n = Decoder(e.t1);
    if (max_side > 0 && n && (w > max_side || h > max_side)) {
        // a smaller mip: the pieces are the mips from the top down (each a quarter of the one before)
        int k = 0;
        while ((w >> k) > max_side || (h >> k) > max_side) ++k;
        if (k < static_cast<int>(pieces.size())) {
            w = (std::max)(1, w >> k);
            h = (std::max)(1, h >> k);
            data = pieces[k];
        }
    }
    std::vector<unsigned char> px;
    if (n) {
        if (!DecodeBlocks(n, w, h, data.data(), data.size(), px)) return "cj_tex_image: truncated";
    } else if (static_cast<size_t>(w) * h * 4 <= data.size()) {
        px.resize(static_cast<size_t>(w) * h * 4);
        for (size_t q = 0; q < px.size(); q += 4) {   // BGRA -> RGBA
            px[q] = data[q + 2];
            px[q + 1] = data[q + 1];
            px[q + 2] = data[q];
            px[q + 3] = data[q + 3];
        }
    } else {
        return "none";
    }
    std::string png;
    stbi_write_png_to_func([](void* ctx, void* d, int len) { static_cast<std::string*>(ctx)->append(
                               static_cast<const char*>(d), len); }, &png, w, h, 4, px.data(), w * 4);
    if (png.empty() || !WriteAll(out_path, png.data(), png.size())) return "cj_tex_image: cannot write";
    *ow = w;
    *oh = h;
    return "";
}

// the worker: jobs in, answers out by their file
struct Job {
    std::string name, out;
    int side;
};
std::mutex g_job_mx;
std::condition_variable g_job_cv;
std::deque<Job> g_job_q;
std::unordered_map<std::string, std::string> g_job_done;   // out -> the answer
std::thread* g_worker = nullptr;    // (never destroyed: Windows ends it with the process)
void Work() {
    for (;;) {
        Job j;
        {
            std::unique_lock<std::mutex> lk(g_job_mx);
            g_job_cv.wait(lk, [] { return !g_job_q.empty(); });
            j = g_job_q.front();
            g_job_q.pop_front();
        }
        int w = 0, h = 0;
        std::string why = MakeImage(j.name, j.side, j.out, &w, &h);
        std::string answer = why.empty() ? std::to_string(w) + "\t" + std::to_string(h) : "!" + why;
        std::lock_guard<std::mutex> lk(g_job_mx);
        g_job_done[j.out] = answer;
    }
}
bool WriteAll(const std::string& path, const void* data, size_t n) {
    std::wstring tmp = Wide(path + ".tmp");
    FILE* o = _wfopen(tmp.c_str(), L"wb");
    if (!o) return false;
    size_t wrote = n ? fwrite(data, 1, n, o) : 0;
    fclose(o);
    if (wrote != n || !MoveFileExW(tmp.c_str(), Wide(path).c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(tmp.c_str());
        return false;
    }
    return true;
}

}  // namespace

int Open(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_tex_open(game)");
    std::wstring game = Wide(argv[0]);
    while (!game.empty() && (game.back() == L'\\' || game.back() == L'/')) game.pop_back();
    if (game != g_game || g_files.empty()) {
        std::vector<std::wstring> a, b;
        for (const auto& d : Dirs(game + L"\\content")) {
            std::wstring p = game + L"\\content\\" + d + L"\\texture.cache";
            if (LowerW(d).compare(0, 7, L"content") == 0 && IsFile(p)) a.push_back(p);
        }
        for (const auto& d : Dirs(game + L"\\dlc")) {
            std::wstring p = game + L"\\dlc\\" + d + L"\\content\\texture.cache";
            if (IsFile(p)) b.push_back(p);
        }
        std::sort(a.begin(), a.end());               // (sorted(glob ...): each list by its paths)
        std::sort(b.begin(), b.end());
        std::lock_guard<std::mutex> lk(g_index_mx);
        g_files = a;
        g_files.insert(g_files.end(), b.begin(), b.end());
        g_index.clear();
        for (uint32_t k = 0; k < g_files.size(); ++k) ReadIndex(k);
        // a DLC's own, also by the path the game knows it by (dlc\bob\data\gameplay\... is gameplay\...; one of the
        // game's own of that path wins): MaximdeWinter 25.10. - Blood and Wine's icons, 870 of the items', were not found
        std::vector<std::pair<std::string, std::string>> more;          // (bare, its full name)
        for (const auto& [name, en] : g_index) {
            if (name.compare(0, 4, "dlc\\") != 0) continue;
            size_t d = name.find("\\data\\", 4);
            if (d == std::string::npos) continue;
            std::string bare = name.substr(d + 6);
            if (!g_index.count(bare)) more.emplace_back(bare, name);
        }
        std::sort(more.begin(), more.end());
        for (auto& [bare, name] : more) g_index.emplace(bare, g_index[name]);   // (two DLCs with one path: the first by name)
        g_game = game;
    }
    snprintf(reply, size, "%zu\t%zu", g_index.size(), g_files.size());
    return 1;
}

int Image(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 3) return Fail(reply, size, "cj_tex_image(name, max_side, out.png)");
    int w = 0, h = 0;
    std::string why = MakeImage(argv[0], atoi(argv[1]), argv[2], &w, &h);
    if (!why.empty()) return Fail(reply, size, why);
    snprintf(reply, size, "%d\t%d", w, h);
    return 1;
}

int ImageAsync(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 3) return Fail(reply, size, "cj_tex_image_async(name, max_side, out.png)");
    {
        std::lock_guard<std::mutex> lk(g_job_mx);
        if (!g_worker) g_worker = new std::thread(Work);
        g_job_done.erase(argv[2]);
        g_job_q.push_back({argv[0], argv[2], atoi(argv[1])});
    }
    g_job_cv.notify_one();
    snprintf(reply, size, "queued");
    return 1;
}

int Status(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_tex_status(out.png)");
    std::lock_guard<std::mutex> lk(g_job_mx);
    auto it = g_job_done.find(argv[0]);
    if (it == g_job_done.end()) {
        snprintf(reply, size, "busy");
        return 1;
    }
    snprintf(reply, size, "%s", it->second.c_str());
    g_job_done.erase(it);
    return 1;
}

int Decode(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 5) return Fail(reply, size, "cj_tex_decode(type1, w, h, in, out)");
    int n = Decoder(static_cast<uint8_t>(atoi(argv[0])));
    int w = atoi(argv[1]), h = atoi(argv[2]);
    FILE* f = _wfopen(Wide(argv[3]).c_str(), L"rb");
    if (!f) return Fail(reply, size, "cj_tex_decode: cannot open the input");
    std::vector<unsigned char> in;
    unsigned char buf[65536];
    size_t got;
    while ((got = fread(buf, 1, sizeof buf, f)) > 0) in.insert(in.end(), buf, buf + got);
    fclose(f);
    std::vector<unsigned char> px;
    if (!n || !DecodeBlocks(n, w, h, in.data(), in.size(), px)) return Fail(reply, size, "cj_tex_decode: cannot");
    if (!WriteAll(argv[4], px.data(), px.size())) return Fail(reply, size, "cj_tex_decode: cannot write");
    snprintf(reply, size, "%zu", px.size());
    return 1;
}

}  // namespace textures

// Zip files as Python's zipfile reads them for the library (library.py, packaging.read_manifest): the central
// directory's names in their order (UTF-8 when the entry says so, else code page 437 as zipfile decodes them),
// stored and deflated entries (stb's inflate), CRC-checked.
//
//   cj_zip_list(zip, out)        out: one line per entry, "<name>\t<size>"            -> "<count>"
//   cj_zip_extract(zip, plan)    plan: lines "<name>\t<target file>" (folders made)  -> "<count>"
//   cj_zip_write(zip, plan)      plan: lines "<name>\t<source file>", deflated as ZipFile(..., ZIP_DEFLATED)
//                                writes them (the time now, UTF-8 names marked)      -> "<count>"
//   cj_zlib(op, source, target)  a zlib stream (header and Adler-32) of a file: op "inflate" or "deflate" (stb's,
//                                level 8) - the terrain's collision.cache entries     -> "<bytes written>"
#include "zip.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>
#include <unordered_map>
#include <vector>

#include "stb_image.h"
#include "stb_image_write.h"

namespace zip {
namespace {

std::wstring Wide(const std::string& s, UINT cp = CP_UTF8) {
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(cp, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(cp, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
    return w;
}
std::string Utf8(const std::wstring& w) {
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), &s[0], n, nullptr, nullptr);
    return s;
}

bool ReadAll(const std::string& path, std::string* out) {
    HANDLE f = CreateFileW(Wide(path).c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(f, &sz) || sz.QuadPart > (1LL << 31)) { CloseHandle(f); return false; }
    out->assign(static_cast<size_t>(sz.QuadPart), '\0');
    DWORD got = 0;
    BOOL ok = out->empty() || ::ReadFile(f, &(*out)[0], static_cast<DWORD>(out->size()), &got, nullptr);
    CloseHandle(f);
    return ok && got == out->size();
}
bool WriteFileAll(const std::string& path, const char* data, size_t n) {
    std::wstring w = Wide(path);
    for (auto& c : w) if (c == L'/') c = L'\\';
    for (size_t i = 3; i < w.size(); ++i) {           // (the folders on the way: os.makedirs)
        if (w[i] == L'\\') CreateDirectoryW(w.substr(0, i).c_str(), nullptr);
    }
    HANDLE f = CreateFileW(w.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    DWORD done = 0;
    BOOL ok = n == 0 || WriteFile(f, data, static_cast<DWORD>(n), &done, nullptr);
    CloseHandle(f);
    return ok && done == n;
}

uint32_t U16(const std::string& d, size_t at) {
    return static_cast<uint8_t>(d[at]) | (static_cast<uint8_t>(d[at + 1]) << 8);
}
uint32_t U32(const std::string& d, size_t at) {
    return U16(d, at) | (U16(d, at + 2) << 16);
}

uint32_t Crc32(const unsigned char* p, size_t n) {
    static uint32_t table[256];
    static bool made = false;
    if (!made) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        made = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) c = table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

struct Entry {
    std::string name;
    uint32_t method, crc, csize, usize, local;
};

// the central directory (the end record found from the back, as zipfile._EndRecData)
std::string Directory(const std::string& d, std::vector<Entry>* out) {
    if (d.size() < 22) return "File is not a zip file";   // (zipfile.BadZipFile's words)
    size_t eocd = std::string::npos;
    size_t lo = d.size() > 22 + 65535 ? d.size() - 22 - 65535 : 0;
    for (size_t i = d.size() - 22 + 1; i-- > lo;) {
        if (U32(d, i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd == std::string::npos) return "File is not a zip file";   // (zipfile.BadZipFile's words)
    uint32_t count = U16(d, eocd + 10);
    uint32_t cd_size = U32(d, eocd + 12);
    uint32_t cd_off = U32(d, eocd + 16);
    if (cd_off == 0xFFFFFFFFu || count == 0xFFFF) return "zip64 is not read";
    // (zipfile: the directory may stand behind data prepended to the archive)
    size_t concat = eocd - cd_size - cd_off;
    size_t at = cd_off + concat;
    for (uint32_t k = 0; k < count; ++k) {
        if (at + 46 > d.size() || U32(d, at) != 0x02014b50) return "broken central directory";
        Entry e;
        uint32_t flags = U16(d, at + 8);
        e.method = U16(d, at + 10);
        e.crc = U32(d, at + 16);
        e.csize = U32(d, at + 20);
        e.usize = U32(d, at + 24);
        uint32_t nlen = U16(d, at + 28), xlen = U16(d, at + 30), clen = U16(d, at + 32);
        e.local = U32(d, at + 42) + static_cast<uint32_t>(concat);
        if (at + 46 + nlen > d.size()) return "broken central directory";
        std::string raw = d.substr(at + 46, nlen);
        e.name = (flags & 0x800) ? raw : Utf8(Wide(raw, 437));
        out->push_back(e);
        at += 46 + nlen + xlen + clen;
    }
    return "";
}

std::string Data(const std::string& d, const Entry& e, std::string* out) {
    if (e.local + 30 > d.size() || U32(d, e.local) != 0x04034b50) return "bad local header: " + e.name;
    size_t start = e.local + 30 + U16(d, e.local + 26) + U16(d, e.local + 28);
    if (start + e.csize > d.size()) return "truncated: " + e.name;
    if (e.method == 0) {
        out->assign(d, start, e.csize);
    } else if (e.method == 8) {
        out->assign(e.usize, '\0');
        if (e.usize > 0) {
            int got = stbi_zlib_decode_noheader_buffer(&(*out)[0], static_cast<int>(e.usize), d.data() + start,
                                                       static_cast<int>(e.csize));
            if (got != static_cast<int>(e.usize)) return "broken data: " + e.name;
        }
    } else {
        return "compression " + std::to_string(e.method) + " is not read: " + e.name;
    }
    if (Crc32(reinterpret_cast<const unsigned char*>(out->data()), out->size()) != e.crc)
        return "bad CRC-32 for file " + e.name;      // (zipfile.BadZipFile's words)
    return "";
}

void Put16(std::string* o, uint32_t v) {
    o->push_back(static_cast<char>(v & 0xff));
    o->push_back(static_cast<char>((v >> 8) & 0xff));
}
void Put32(std::string* o, uint32_t v) { Put16(o, v & 0xffff); Put16(o, v >> 16); }

}  // namespace
}  // namespace zip
// (stb_image_write's, implemented in cj_core.cpp; the header declares it only with the implementation)
extern "C" unsigned char* stbi_zlib_compress(unsigned char* data, int data_len, int* out_len, int quality);
namespace zip {
namespace {

// raw deflate of data (stb's zlib stream without its 2-byte header and Adler-32)
std::string Deflate(const std::string& data) {
    int n = 0;
    unsigned char* z = stbi_zlib_compress(reinterpret_cast<unsigned char*>(const_cast<char*>(data.data())),
                                          static_cast<int>(data.size()), &n, 8);
    std::string out;
    if (z && n > 6) out.assign(reinterpret_cast<char*>(z) + 2, n - 6);
    free(z);                                            // (stb's default STBIW_FREE)
    return out;
}

int Fail(char* reply, uint32_t size, const std::string& s) {
    snprintf(reply, size, "%s", s.c_str());
    return 0;
}

}  // namespace

int Write(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_zip_write(zip, plan)");
    std::string plan;
    if (!ReadAll(argv[1], &plan)) return Fail(reply, size, std::string("cj_zip_write: cannot read ") + argv[1]);
    SYSTEMTIME t;
    GetLocalTime(&t);                                   // (zipfile: time.localtime() for writestr)
    const uint32_t dtime = (t.wHour << 11) | (t.wMinute << 5) | (t.wSecond / 2);
    const uint32_t ddate = ((t.wYear - 1980) << 9) | (t.wMonth << 5) | t.wDay;
    std::string body, dir;
    unsigned n = 0;
    size_t at = 0;
    while (at < plan.size()) {
        size_t end = plan.find('\n', at);
        if (end == std::string::npos) end = plan.size();
        std::string line = plan.substr(at, end - at);
        at = end + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t tab = line.find('\t');
        if (tab == std::string::npos) continue;
        std::string name = line.substr(0, tab), src = line.substr(tab + 1);
        std::string data;
        if (!ReadAll(src, &data)) return Fail(reply, size, "cj_zip_write: cannot read " + src);
        std::string z = Deflate(data);
        if (z.empty() && !data.empty()) return Fail(reply, size, "cj_zip_write: cannot compress " + name);
        bool ascii = true;
        for (unsigned char c : name) if (c >= 0x80) ascii = false;
        const uint32_t flags = ascii ? 0 : 0x800;
        const uint32_t crc = Crc32(reinterpret_cast<const unsigned char*>(data.data()), data.size());
        const uint32_t local = static_cast<uint32_t>(body.size());
        Put32(&body, 0x04034b50); Put16(&body, 20); Put16(&body, flags); Put16(&body, 8);
        Put16(&body, dtime); Put16(&body, ddate); Put32(&body, crc);
        Put32(&body, static_cast<uint32_t>(z.size())); Put32(&body, static_cast<uint32_t>(data.size()));
        Put16(&body, static_cast<uint32_t>(name.size())); Put16(&body, 0);
        body += name;
        body += z;
        Put32(&dir, 0x02014b50); Put16(&dir, 20); Put16(&dir, 20); Put16(&dir, flags); Put16(&dir, 8);
        Put16(&dir, dtime); Put16(&dir, ddate); Put32(&dir, crc);
        Put32(&dir, static_cast<uint32_t>(z.size())); Put32(&dir, static_cast<uint32_t>(data.size()));
        Put16(&dir, static_cast<uint32_t>(name.size())); Put16(&dir, 0); Put16(&dir, 0); Put16(&dir, 0);
        Put16(&dir, 0); Put32(&dir, 0x81a40000u);     // (-rw-r--r--, as zipfile's writestr)
        Put32(&dir, local);
        dir += name;
        ++n;
    }
    std::string out = body + dir;
    Put32(&out, 0x06054b50); Put16(&out, 0); Put16(&out, 0); Put16(&out, n); Put16(&out, n);
    Put32(&out, static_cast<uint32_t>(dir.size())); Put32(&out, static_cast<uint32_t>(body.size())); Put16(&out, 0);
    if (!WriteFileAll(argv[0], out.data(), out.size()))
        return Fail(reply, size, std::string("cj_zip_write: cannot write ") + argv[0]);
    snprintf(reply, size, "%u", n);
    return 1;
}

int List(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_zip_list(zip, out)");
    std::string d;
    if (!ReadAll(argv[0], &d)) return Fail(reply, size, std::string("cj_zip_list: cannot read ") + argv[0]);
    std::vector<Entry> es;
    std::string err = Directory(d, &es);
    if (!err.empty()) return Fail(reply, size, "cj_zip_list: " + err);
    std::string text;
    for (const auto& e : es) text += e.name + "\t" + std::to_string(e.usize) + "\n";
    if (!WriteFileAll(argv[1], text.data(), text.size()))
        return Fail(reply, size, std::string("cj_zip_list: cannot write ") + argv[1]);
    snprintf(reply, size, "%u", static_cast<unsigned>(es.size()));
    return 1;
}

int Extract(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_zip_extract(zip, plan)");
    std::string d, plan;
    if (!ReadAll(argv[0], &d)) return Fail(reply, size, std::string("cj_zip_extract: cannot read ") + argv[0]);
    if (!ReadAll(argv[1], &plan)) return Fail(reply, size, std::string("cj_zip_extract: cannot read ") + argv[1]);
    std::vector<Entry> es;
    std::string err = Directory(d, &es);
    if (!err.empty()) return Fail(reply, size, "cj_zip_extract: " + err);
    std::unordered_map<std::string, size_t> by_name;
    for (size_t i = 0; i < es.size(); ++i) by_name[es[i].name] = i;   // (the last of a name, as NameToInfo)
    unsigned n = 0;
    size_t at = 0;
    while (at < plan.size()) {
        size_t end = plan.find('\n', at);
        if (end == std::string::npos) end = plan.size();
        std::string line = plan.substr(at, end - at);
        at = end + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t tab = line.find('\t');
        if (tab == std::string::npos) continue;
        std::string name = line.substr(0, tab), target = line.substr(tab + 1);
        auto it = by_name.find(name);
        if (it == by_name.end()) return Fail(reply, size, "cj_zip_extract: no " + name);
        std::string data;
        err = Data(d, es[it->second], &data);
        if (!err.empty()) return Fail(reply, size, "cj_zip_extract: " + err);
        if (!WriteFileAll(target, data.data(), data.size()))
            return Fail(reply, size, "cj_zip_extract: cannot write " + target);
        ++n;
    }
    snprintf(reply, size, "%u", n);
    return 1;
}

int Zlib(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 3) return Fail(reply, size, "cj_zlib(op, source, target)");
    const std::string op = argv[0];
    std::string d;
    if (!ReadAll(argv[1], &d)) return Fail(reply, size, std::string("cj_zlib: cannot read ") + argv[1]);
    std::string out;
    if (op == "inflate") {
        int n = 0;
        char* z = stbi_zlib_decode_malloc(d.data(), static_cast<int>(d.size()), &n);
        if (!z) return Fail(reply, size, "cj_zlib: not a zlib stream");
        out.assign(z, n);
        free(z);                                        // (stb_image's default STBI_FREE)
    } else if (op == "deflate") {
        int n = 0;
        unsigned char* z = stbi_zlib_compress(reinterpret_cast<unsigned char*>(&d[0]), static_cast<int>(d.size()),
                                              &n, 8);
        if (!z) return Fail(reply, size, "cj_zlib: cannot compress");
        out.assign(reinterpret_cast<char*>(z), n);
        free(z);
    } else {
        return Fail(reply, size, "cj_zlib: op is inflate or deflate");
    }
    if (!WriteFileAll(argv[2], out.data(), out.size()))
        return Fail(reply, size, std::string("cj_zlib: cannot write ") + argv[2]);
    snprintf(reply, size, "%u", static_cast<unsigned>(out.size()));
    return 1;
}

}  // namespace zip

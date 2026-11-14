// cj_core: Conjunction's native part in the game, a TW3SE plugin (tw3se\plugins\cj_core.dll). For now the asset
// database: SQLite 3.50.4 with FTS5, the version and options of the app's Python (sqlite3.sqlite_version, pragma
// compile_options), so the same SQL gives the same rows and the same bm25 scores.
//
// Lua (w3.plugin.<name>, the arguments as text):
//   cj_db_open(path [, "memory"])        -> id       the file read-only; "memory": read into memory, the file let go;
//                                                    "write": read and written, made when it is not there
//                                                    (assets.Assets: a rebuild may replace it while the editor runs)
//   cj_db_exec(id, sql, param ...)       -> changes  a statement (insert, delete ...)
//   cj_db_query(id, sql, param ...)      -> the rows as a Lua chunk (TW3SE 20), else "file\trows" (written there)
//   cj_db_close(id)
//   cj_hash("md5" | "sha1" | "sha256", text) -> hex
//   cj_img_qt(src, out, w, h [, "rrggbb"]) -> "w\th"   a picture as Qt scales and draws it (ImgQt)
//   cj_img_size(path) -> "w\th"
//   cj_depot_open / exists / read / glob     the game's files out of its bundles (depot.cpp)
//   cj_tex_open / image / decode             pictures out of the texture caches (textures.cpp)
//   cj_mosaic / _async / _status              the Asset Browser's folder pictures (mosaic.cpp)
//   cj_thumb / _async                         its pictures out of REDkit's thumbnails (mosaic.cpp)
//   cj_shell_icon                             Windows' icons as Qt's dialogs show them (shellicons.cpp)
//   cj_zip_list / _extract / _write / cj_zlib quest files (.w3q), bug reports: zip files; zlib streams (zip.cpp)
//   cj_py_stat                                a file's size and st_mtime as Python gives them (pystat.cpp)
//   cj_ed25519_* / cj_random / cj_hmac_sha256 / cj_sha256_parts   a profile's signatures, the history (crypto.cpp)
//   cj_lz4hc_file(source, target)   a file as one LZ4 HC block (lz4pack.cpp: the bundle packer)
//   cj_keep_running("on" | "off")   the game keeps running while another window is in front (keeprun.cpp)
// A parameter is typed by its first letters: "s:text", "i:12", "r:1.5", "n" (NULL). A query's rows go to a file as a
// Lua chunk (a reply holds 4 KB, the catalog reads 23 000 rows at once): run with Y.null as its argument it returns
// the column names and the rows, {{v, v, ...}, ...}, NULL as that argument. Integers stay integers, reals are
// written with 17 digits (the same double again).
#include "tw3se/tw3se.h"
#include "sqlite3.h"
#include "qtscale.h"
#include "depot.h"
#include "textures.h"
#include "mosaic.h"
#include "shellicons.h"
#include "zip.h"
#include "pystat.h"
#include "crypto.h"
#include "lz4pack.h"
#include "buildsys.h"
#ifndef CJ_NO_KEEPRUN
#include "keeprun.h"
#endif

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <windows.h>
#include <bcrypt.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>
#include <vector>

#pragma comment(lib, "bcrypt.lib")

namespace {
const TW3SE_Interface* g_api = nullptr;
std::vector<sqlite3*> g_dbs;  // id = index + 1 (a closed one stays nullptr)
std::string g_dir;            // %TEMP%\cj_core\ (UTF-8)

int Fail(char* reply, uint32_t size, const char* fmt, ...) {
    va_list a;
    va_start(a, fmt);
    vsnprintf(reply, size, fmt, a);
    va_end(a);
    return 0;
}

std::string Utf8(const wchar_t* w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
    return s;
}

std::wstring Wide(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
    return w;
}

const std::string& Dir() {
    if (g_dir.empty()) {
        wchar_t t[MAX_PATH + 1] = {};
        GetTempPathW(MAX_PATH, t);
        std::wstring d = std::wstring(t) + L"cj_core\\";
        CreateDirectoryW(d.c_str(), nullptr);
        g_dir = Utf8(d.c_str());
    }
    return g_dir;
}

sqlite3* Db(const char* id) {
    long i = strtol(id ? id : "0", nullptr, 10);
    return i >= 1 && static_cast<size_t>(i) <= g_dbs.size() ? g_dbs[i - 1] : nullptr;
}

// the parameters from argv[first] on, typed by their first letters
bool Bind(sqlite3_stmt* st, int argc, const char* const* argv, int first, char* reply, uint32_t size) {
    for (int k = first; k < argc; ++k) {
        const char* a = argv[k];
        int n = k - first + 1, rc;
        if (a[0] == 's' && a[1] == ':') rc = sqlite3_bind_text(st, n, a + 2, -1, SQLITE_TRANSIENT);
        else if (a[0] == 'i' && a[1] == ':') rc = sqlite3_bind_int64(st, n, _strtoi64(a + 2, nullptr, 10));
        else if (a[0] == 'r' && a[1] == ':') rc = sqlite3_bind_double(st, n, strtod(a + 2, nullptr));
        else if (a[0] == 'n' && a[1] == 0) rc = sqlite3_bind_null(st, n);
        else {
            Fail(reply, size, "cj_db: parameter %d is not typed (s:, i:, r:, n): %.60s", n, a);
            return false;
        }
        if (rc != SQLITE_OK) {
            Fail(reply, size, "cj_db: parameter %d: %s", n, sqlite3_errstr(rc));
            return false;
        }
    }
    return true;
}

sqlite3_stmt* Prepare(sqlite3* db, const char* sql, int argc, const char* const* argv, int first, char* reply,
                      uint32_t size) {
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db, sql, -1, &st, nullptr) != SQLITE_OK) {
        Fail(reply, size, "cj_db: %s", sqlite3_errmsg(db));
        return nullptr;
    }
    if (!Bind(st, argc, argv, first, reply, size)) {
        sqlite3_finalize(st);
        return nullptr;
    }
    return st;
}

// a value as Lua source
void Put(std::string& out, sqlite3_stmt* st, int c) {
    char buf[64];
    switch (sqlite3_column_type(st, c)) {
    case SQLITE_INTEGER: {
        long long v = sqlite3_column_int64(st, c);
        if (v == LLONG_MIN) out += "(-9223372036854775807-1)";
        else {
            snprintf(buf, sizeof buf, "%lld", v);
            out += buf;
        }
        break;
    }
    case SQLITE_FLOAT: {
        double v = sqlite3_column_double(st, c);
        if (v != v) out += "(0/0)";
        else if (v > 1.7976931348623157e308) out += "1e999";
        else if (v < -1.7976931348623157e308) out += "-1e999";
        else {
            snprintf(buf, sizeof buf, "%.17g", v);
            out += buf;
            if (!strpbrk(buf, ".e")) out += ".0";   // (a float, as Python's: 2.0 is not the integer 2)
        }
        break;
    }
    case SQLITE_NULL:
        out += "N";
        break;
    default: {  // text and blobs: a Lua string, bytes under 32, '"', '\' and 127 as \ddd
        const unsigned char* p = static_cast<const unsigned char*>(sqlite3_column_blob(st, c));
        int n = sqlite3_column_bytes(st, c);
        out += '"';
        for (int i = 0; i < n; ++i) {
            unsigned char b = p[i];
            if (b < 32 || b == '"' || b == '\\' || b == 127) {
                snprintf(buf, sizeof buf, "\\%03u", b);
                out += buf;
            } else {
                out += static_cast<char>(b);
            }
        }
        out += '"';
    }
    }
}

int DbOpen(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_db_open(path [, \"memory\"])");
    bool memory = argc >= 2 && !strcmp(argv[1], "memory");
    bool write = argc >= 2 && !strcmp(argv[1], "write");
    sqlite3* file = nullptr;
    int flags = write ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY;
    if (sqlite3_open_v2(argv[0], &file, flags, nullptr) != SQLITE_OK) {
        Fail(reply, size, "cj_db_open: %s: %s", argv[0], file ? sqlite3_errmsg(file) : "no memory");
        sqlite3_close(file);
        return 0;
    }
    sqlite3* db = file;
    if (memory) {
        db = nullptr;
        if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
            sqlite3_close(file);
            sqlite3_close(db);
            return Fail(reply, size, "cj_db_open: no memory database");
        }
        sqlite3_backup* b = sqlite3_backup_init(db, "main", file, "main");
        int rc = b ? sqlite3_backup_step(b, -1) : SQLITE_ERROR;
        sqlite3_backup_finish(b);
        sqlite3_close(file);
        if (rc != SQLITE_DONE) {
            Fail(reply, size, "cj_db_open: reading %s: %s", argv[0], sqlite3_errmsg(db));
            sqlite3_close(db);
            return 0;
        }
    }
    g_dbs.push_back(db);
    snprintf(reply, size, "%u", static_cast<unsigned>(g_dbs.size()));
    return 1;
}

int DbExec(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    sqlite3* db = argc >= 2 ? Db(argv[0]) : nullptr;
    if (!db) return Fail(reply, size, "cj_db_exec(id, sql, param ...): no such database");
    sqlite3_stmt* st = Prepare(db, argv[1], argc, argv, 2, reply, size);
    if (!st) return 0;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {}
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return Fail(reply, size, "cj_db_exec: %s", sqlite3_errmsg(db));
    snprintf(reply, size, "%d", sqlite3_changes(db));
    return 1;
}

int DbQuery(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    sqlite3* db = argc >= 2 ? Db(argv[0]) : nullptr;
    if (!db) return Fail(reply, size, "cj_db_query(id, sql, param ...): no such database");
    sqlite3_stmt* st = Prepare(db, argv[1], argc, argv, 2, reply, size);
    if (!st) return 0;
    std::string out = "local N = ...\nreturn {";
    int cols = sqlite3_column_count(st);
    for (int c = 0; c < cols; ++c) {
        const char* name = sqlite3_column_name(st, c);
        out += c ? ", \"" : "\"";
        for (const char* p = name; *p; ++p) {
            if (*p == '"' || *p == '\\') out += '\\';
            out += *p;
        }
        out += '"';
    }
    out += "}, {\n";
    int rc, rows = 0;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        out += '{';
        for (int c = 0; c < cols; ++c) {
            if (c) out += ", ";
            Put(out, st, c);
        }
        out += "},\n";
        ++rows;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return Fail(reply, size, "cj_db_query: %s", sqlite3_errmsg(db));
    out += "}\n";
    // (the chunk straight to Lua with TW3SE 20; else through a file - 25.10.: the catalog's rows, written and read)
    if (g_api && g_api->interfaceVersion >= 20 && g_api->LuaReplyBytes) {
        g_api->LuaReplyBytes(out.data(), out.size());
        return 1;
    }
    std::string path = Dir() + "q" + argv[0] + ".lua";
    FILE* f = _wfopen(Wide(path).c_str(), L"wb");
    if (!f) return Fail(reply, size, "cj_db_query: cannot write %s", path.c_str());
    size_t w = fwrite(out.data(), 1, out.size(), f);
    fclose(f);
    if (w != out.size()) return Fail(reply, size, "cj_db_query: %s not written whole", path.c_str());
    snprintf(reply, size, "%s\t%d", path.c_str(), rows);
    return 1;
}

// cj_hash(algorithm, text) -> hex: "md5", "sha1" or "sha256" of the text's bytes (hashlib's hexdigest), with
// Windows' CNG (no code of our own to get wrong)
int Hash(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_hash(algorithm, text)");
    LPCWSTR alg = !strcmp(argv[0], "md5") ? BCRYPT_MD5_ALGORITHM
                  : !strcmp(argv[0], "sha1") ? BCRYPT_SHA1_ALGORITHM
                  : !strcmp(argv[0], "sha256") ? BCRYPT_SHA256_ALGORITHM : nullptr;
    if (!alg) return Fail(reply, size, "cj_hash: no algorithm %s (md5, sha1, sha256)", argv[0]);
    BCRYPT_ALG_HANDLE h = nullptr;
    if (BCryptOpenAlgorithmProvider(&h, alg, nullptr, 0) != 0) return Fail(reply, size, "cj_hash: no provider");
    unsigned char digest[32];
    DWORD len = 0, got = 0;
    BCryptGetProperty(h, BCRYPT_HASH_LENGTH, reinterpret_cast<PUCHAR>(&len), sizeof len, &got, 0);
    NTSTATUS st = len <= sizeof digest
                      ? BCryptHash(h, nullptr, 0, reinterpret_cast<PUCHAR>(const_cast<char*>(argv[1])),
                                   static_cast<ULONG>(strlen(argv[1])), digest, len)
                      : -1;
    BCryptCloseAlgorithmProvider(h, 0);
    if (st != 0) return Fail(reply, size, "cj_hash: failed");
    for (DWORD i = 0; i < len && 2 * i + 2 < size; ++i) snprintf(reply + 2 * i, 3, "%02x", digest[i]);
    return 1;
}

// --- pictures as the app's Qt shows them ---
// premultiplied as Qt's ARGB32 -> ARGB32_Premultiplied (checked on every colour and alpha), BYTE_MUL as Qt's
inline uint32_t Div255(uint32_t t) { return (t + (t >> 8) + 0x80) >> 8; }
inline uint32_t PremulPixel(uint32_t p) {
    uint32_t a = p >> 24;
    if (a == 255) return p;
    if (a == 0) return 0;
    return (a << 24) | (Div255(((p >> 16) & 0xff) * a) << 16) | (Div255(((p >> 8) & 0xff) * a) << 8) |
           Div255((p & 0xff) * a);
}
// QPainter's source over of a premultiplied pixel onto an opaque one (Qt's blend_pixel)
inline uint32_t BlendOnto(uint32_t src, uint32_t dst) {
    uint32_t a = src >> 24;
    if (a == 255) return src;
    if (src == 0) return dst;
    uint32_t ia = 255 - a, out = 0xff000000u;
    for (int s = 0; s < 24; s += 8) out |= ((((src >> s) & 0xff) + Div255(((dst >> s) & 0xff) * ia)) & 0xff) << s;
    return out;
}
// qUnpremultiply (a picture kept with its transparency)
inline uint32_t Unpremul(uint32_t p) {
    uint32_t a = p >> 24;
    if (a == 255 || a == 0) return p;
    uint32_t inv = (255u << 16) / a, out = a << 24;
    for (int s = 0; s < 24; s += 8) out |= ((((p >> s) & 0xff) * inv + 0x8000) >> 16) << s;
    return out;
}

// cj_img_qt(src, out, w, h [, "rrggbb"]) -> "w\th": the picture file as QPixmap(src).scaled(w, h) is (Qt's smooth
// scaling, the size given exactly - the caller works out KeepAspectRatio), drawn onto that colour as QPainter draws
// it (then opaque), or kept with its transparency; written as a PNG
int ImgQt(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 4) return Fail(reply, size, "cj_img_qt(src, out, w, h [, rrggbb])");
    int dw = atoi(argv[2]), dh = atoi(argv[3]);
    int w = 0, h = 0, n = 0;
    FILE* f = _wfopen(Wide(argv[0]).c_str(), L"rb");
    if (!f) return Fail(reply, size, "cj_img_qt: cannot open %s", argv[0]);
    unsigned char* px = stbi_load_from_file(f, &w, &h, &n, 4);
    fclose(f);
    if (!px) return Fail(reply, size, "cj_img_qt: %s: %s", argv[0], stbi_failure_reason());
    if (dw <= 0 || dh <= 0) {
        stbi_image_free(px);
        return Fail(reply, size, "cj_img_qt: a size of %d x %d", dw, dh);
    }
    std::vector<uint32_t> src(static_cast<size_t>(w) * h), dst(static_cast<size_t>(dw) * dh);
    for (size_t i = 0; i < src.size(); ++i) {
        const unsigned char* q = px + 4 * i;
        src[i] = PremulPixel((uint32_t(q[3]) << 24) | (uint32_t(q[0]) << 16) | (uint32_t(q[1]) << 8) | q[2]);
    }
    stbi_image_free(px);
    if (dw == w && dh == h) dst = src;          // (QPixmap::scaled to its own size: the same pixmap)
    else qtscale::SmoothScale(src.data(), w, h, dst.data(), dw, dh, true);
    bool onto = argc >= 5 && argv[4][0];
    uint32_t bg = onto ? 0xff000000u | static_cast<uint32_t>(strtoul(argv[4], nullptr, 16)) : 0;
    std::vector<unsigned char> out(dst.size() * 4);
    for (size_t i = 0; i < dst.size(); ++i) {
        uint32_t p = onto ? BlendOnto(dst[i], bg) : Unpremul(dst[i]);
        out[4 * i] = (p >> 16) & 0xff;
        out[4 * i + 1] = (p >> 8) & 0xff;
        out[4 * i + 2] = p & 0xff;
        out[4 * i + 3] = p >> 24;
    }
    std::string png;
    stbi_write_png_to_func([](void* ctx, void* data, int n) { static_cast<std::string*>(ctx)->append(
                               static_cast<const char*>(data), n); }, &png, dw, dh, 4, out.data(), dw * 4);
    std::string tmp = std::string(argv[1]) + ".tmp";
    FILE* o = _wfopen(Wide(tmp).c_str(), L"wb");       // (a UTF-8 path: stb's own writer takes the ANSI one)
    size_t wrote = o ? fwrite(png.data(), 1, png.size(), o) : 0;
    if (o) fclose(o);
    if (png.empty() || wrote != png.size()) return Fail(reply, size, "cj_img_qt: cannot write %s", argv[1]);
    if (!MoveFileExW(Wide(tmp).c_str(), Wide(argv[1]).c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(Wide(tmp).c_str());
        return Fail(reply, size, "cj_img_qt: cannot put %s in place", argv[1]);
    }
    snprintf(reply, size, "%d\t%d", dw, dh);
    return 1;
}

// cj_img_size(path) -> "w\th"
int ImgSize(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_img_size(path)");
    int w = 0, h = 0, n = 0;
    FILE* f = _wfopen(Wide(argv[0]).c_str(), L"rb");
    if (!f || !stbi_info_from_file(f, &w, &h, &n)) {
        if (f) fclose(f);
        return Fail(reply, size, "cj_img_size: %s", argv[0]);
    }
    fclose(f);
    snprintf(reply, size, "%d\t%d", w, h);
    return 1;
}

int DbClose(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    long i = argc >= 1 ? strtol(argv[0], nullptr, 10) : 0;
    if (i >= 1 && static_cast<size_t>(i) <= g_dbs.size() && g_dbs[i - 1]) {
        sqlite3_close(g_dbs[i - 1]);
        g_dbs[i - 1] = nullptr;
        DeleteFileW(Wide(Dir() + "q" + argv[0] + ".lua").c_str());
    }
    reply[0] = 0;
    return 1;
}
}  // namespace

TW3SE_EXPORT int TW3SE_PluginQuery(TW3SE_PluginInfo* info) {
    info->name = "cj_core";
    info->author = "Conjunction";
    info->version = 0x00000100;
    info->minInterface = 16;  // RegisterLuaFunction
    return 1;
}

TW3SE_EXPORT int TW3SE_PluginLoad(const TW3SE_Interface* api) {
    g_api = api;
    if (sqlite3_initialize() != SQLITE_OK) {  // (SQLITE_OMIT_AUTOINIT, as Python's: it calls this itself)
        api->Log("cj_core", "SQLite did not start");
        return 0;
    }
    api->RegisterLuaFunction("cj_db_open", &DbOpen, nullptr);
    api->RegisterLuaFunction("cj_db_exec", &DbExec, nullptr);
    api->RegisterLuaFunction("cj_db_query", &DbQuery, nullptr);
    api->RegisterLuaFunction("cj_db_close", &DbClose, nullptr);
    api->RegisterLuaFunction("cj_hash", &Hash, nullptr);
    api->RegisterLuaFunction("cj_img_qt", &ImgQt, nullptr);
    api->RegisterLuaFunction("cj_img_size", &ImgSize, nullptr);
    api->RegisterLuaFunction("cj_depot_open", &depot::Open, nullptr);
    api->RegisterLuaFunction("cj_depot_exists", &depot::Exists, nullptr);
    api->RegisterLuaFunction("cj_depot_read", &depot::ReadTo, nullptr);
    api->RegisterLuaFunction("cj_depot_data", &depot::Data, nullptr);
    api->RegisterLuaFunction("cj_mesh_rows", &depot::MeshRows, nullptr);
    depot::g_reply_bytes = api->interfaceVersion >= 20 ? api->LuaReplyBytes : nullptr;
    api->RegisterLuaFunction("cj_depot_glob", &depot::Glob, nullptr);
    api->RegisterLuaFunction("cj_depot_glob_where", &depot::GlobWhere, nullptr);
    api->RegisterLuaFunction("cj_bundle_read", &depot::BundleRead, nullptr);
    api->RegisterLuaFunction("cj_tex_open", &textures::Open, nullptr);
    api->RegisterLuaFunction("cj_tex_image", &textures::Image, nullptr);
    api->RegisterLuaFunction("cj_tex_decode", &textures::Decode, nullptr);
    api->RegisterLuaFunction("cj_tex_image_async", &textures::ImageAsync, nullptr);
    api->RegisterLuaFunction("cj_tex_status", &textures::Status, nullptr);
    api->RegisterLuaFunction("cj_depot_open_async", &depot::OpenAsync, nullptr);
    api->RegisterLuaFunction("cj_mosaic", &mosaic::Now, nullptr);
    api->RegisterLuaFunction("cj_mosaic_async", &mosaic::Async, nullptr);
    api->RegisterLuaFunction("cj_mosaic_status", &mosaic::Status, nullptr);
    api->RegisterLuaFunction("cj_thumb", &mosaic::Thumb, nullptr);
    api->RegisterLuaFunction("cj_thumb_async", &mosaic::ThumbAsync, nullptr);
    api->RegisterLuaFunction("cj_shell_icon", &shellicons::Icon, nullptr);
    api->RegisterLuaFunction("cj_zip_list", &zip::List, nullptr);
    api->RegisterLuaFunction("cj_zip_extract", &zip::Extract, nullptr);
    api->RegisterLuaFunction("cj_zip_write", &zip::Write, nullptr);
    api->RegisterLuaFunction("cj_zlib", &zip::Zlib, nullptr);
    api->RegisterLuaFunction("cj_py_stat", &pystat::Stat, nullptr);
    api->RegisterLuaFunction("cj_ed25519_public", &crypto::Ed25519Public, nullptr);
    api->RegisterLuaFunction("cj_ed25519_sign", &crypto::Ed25519Sign, nullptr);
    api->RegisterLuaFunction("cj_ed25519_verify", &crypto::Ed25519Verify, nullptr);
    api->RegisterLuaFunction("cj_random", &crypto::Random, nullptr);
    api->RegisterLuaFunction("cj_hmac_sha256", &crypto::HmacSha256, nullptr);
    api->RegisterLuaFunction("cj_sha256_parts", &crypto::Sha256Parts, nullptr);
    api->RegisterLuaFunction("cj_lz4hc_file", &lz4pack::CompressFile, nullptr);
    api->RegisterLuaFunction("cj_hardlink", &buildsys::HardLink, nullptr);
    api->RegisterLuaFunction("cj_redkit_eula_keep", &buildsys::RedkitEulaKeep, nullptr);
    api->RegisterLuaFunction("cj_file_attributes", &buildsys::FileAttributes, nullptr);
#ifndef CJ_NO_KEEPRUN
    keeprun::Init(api);
    api->RegisterLuaFunction("cj_keep_running", &keeprun::KeepRunning, nullptr);
#endif
    int parked = buildsys::ParkPending();          // (before the engine mounts the dlc folder: old runs out)
    if (parked) api->Log("cj_core", "parked %d folders the last Build & Play left for this start", parked);
    stbi_write_png_compression_level = 1;   // (the same pixels, written several times faster)
    api->Log("cj_core", "loaded (SQLite %s)", sqlite3_libversion());
    return 1;
}

TW3SE_EXPORT int TW3SE_PluginUnload(void) {
#ifndef CJ_NO_KEEPRUN
    keeprun::Unload();
#endif
    for (sqlite3*& db : g_dbs) {
        if (db) sqlite3_close(db);
        db = nullptr;
    }
    return 0;
}

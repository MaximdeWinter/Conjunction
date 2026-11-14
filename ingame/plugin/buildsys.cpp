// What the build needs of Windows beyond w3.fs and w3.proc (build.py's os.link, setup.keep_redkit_eula):
//   cj_hardlink(source, target) -> "1"            a hard link (build.link_from_depot: the game's files into r4data)
//   cj_redkit_eula_keep() -> "1" | "0"             REDkit's DoNotShowEula, accepted by the user as the DWORD 1 that
//                                                  wcc_lite cannot read back, kept as the 1-byte value it can read
//                                                  ("1": changed). Never sets anything the user has not accepted.
//   cj_file_attributes(path [, attributes]) -> them   GetFileAttributes, SetFileAttributes first when given (the
//                                                  export's hidden id file: 2 hidden, 128 normal)
// Paths are UTF-8.
#include "buildsys.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#pragma comment(lib, "advapi32.lib")

#include <cstdio>
#include <cstdlib>
#include <string>

namespace buildsys {
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

std::string Utf8(const std::wstring& w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), &s[0], n, nullptr, nullptr);
    return s;
}

}  // namespace

int HardLink(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_hardlink(source, target)");
    if (!CreateHardLinkW(Wide(argv[1]).c_str(), Wide(argv[0]).c_str(), nullptr)) {
        return Fail(reply, size, "cj_hardlink: error " + std::to_string(GetLastError()));
    }
    snprintf(reply, size, "1");
    return 1;
}

int FileAttributes(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_file_attributes(path [, attributes])");
    std::wstring p = Wide(argv[0]);
    if (argc >= 2 && !SetFileAttributesW(p.c_str(), static_cast<DWORD>(strtoul(argv[1], nullptr, 10)))) {
        return Fail(reply, size, "cj_file_attributes: error " + std::to_string(GetLastError()));
    }
    DWORD a = GetFileAttributesW(p.c_str());
    if (a == INVALID_FILE_ATTRIBUTES) return Fail(reply, size, "cj_file_attributes: no " + std::string(argv[0]));
    snprintf(reply, size, "%lu", static_cast<unsigned long>(a));
    return 1;
}

// The game's folder: three up from bin\x64_dx12\witcher3.exe
static std::wstring GameRoot() {
    wchar_t exe[MAX_PATH * 2] = {0};
    GetModuleFileNameW(nullptr, exe, MAX_PATH * 2);
    std::wstring p(exe);
    for (int i = 0; i < 3; ++i) {
        size_t s = p.find_last_of(L"\\/");
        if (s == std::wstring::npos) return L"";
        p = p.substr(0, s);
    }
    return p;
}

static void MakeDirs(const std::wstring& dir) {
    if (dir.empty() || GetFileAttributesW(dir.c_str()) != INVALID_FILE_ATTRIBUTES) return;
    size_t s = dir.find_last_of(L"\\/");
    if (s != std::wstring::npos) MakeDirs(dir.substr(0, s));
    CreateDirectoryW(dir.c_str(), nullptr);
}

int ParkPending() {
    std::wstring root = GameRoot();
    if (root.empty()) return 0;
    std::wstring parked = root + L"\\_conjunction_parked";
    std::wstring list = parked + L"\\pending.txt";
    FILE* f = _wfopen(list.c_str(), L"rb");
    if (!f) return 0;
    std::string text;
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) text.append(buf, n);
    fclose(f);
    std::string left, said;
    int moved = 0;
    size_t at = 0;
    while (at < text.size()) {
        size_t end = text.find('\n', at);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(at, end - at);
        at = end + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t tab = line.find('\t');
        if (tab == std::string::npos) continue;
        std::wstring src = root + L"\\" + Wide(line.substr(0, tab).c_str());
        std::wstring dst = root + L"\\" + Wide(line.substr(tab + 1).c_str());
        if (GetFileAttributesW(src.c_str()) == INVALID_FILE_ATTRIBUTES) continue;   // (gone already)
        std::wstring target = dst;
        for (int k = 2; GetFileAttributesW(target.c_str()) != INVALID_FILE_ATTRIBUTES; ++k) {
            target = dst + L"." + std::to_wstring(k);       // (parked before: the older one keeps its name)
        }
        size_t s = target.find_last_of(L"\\/");
        if (s != std::wstring::npos) MakeDirs(target.substr(0, s));
        if (MoveFileExW(src.c_str(), target.c_str(), 0)) {
            ++moved;
            said += "parked " + line.substr(0, tab) + " -> " + Utf8(target) + "\n";
        } else {
            left += line + "\n";
            said += "stays " + line.substr(0, tab) + " (error " + std::to_string(GetLastError()) + ")\n";
        }
    }
    if (left.empty()) {
        DeleteFileW(list.c_str());
    } else if (FILE* o = _wfopen(list.c_str(), L"wb")) {
        fwrite(left.data(), 1, left.size(), o);
        fclose(o);
    }
    if (FILE* lg = _wfopen((parked + L"\\parked.log").c_str(), L"ab")) {
        fwrite(said.data(), 1, said.size(), lg);
        fclose(lg);
    }
    return moved;
}

int RedkitEulaKeep(int, const char* const*, char* reply, uint32_t size, void*) {
    HKEY k = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\CD Projekt RED\\Mod Tools\\1.0", 0, KEY_QUERY_VALUE | KEY_SET_VALUE,
                      &k) != ERROR_SUCCESS) {
        snprintf(reply, size, "0");
        return 1;
    }
    DWORD kind = 0, v = 0, n = sizeof v;
    bool changed = false;
    if (RegQueryValueExW(k, L"DoNotShowEula", nullptr, &kind, reinterpret_cast<BYTE*>(&v), &n) == ERROR_SUCCESS &&
        kind == REG_DWORD && n == sizeof v && v == 1) {
        BYTE one = 1;
        changed = RegSetValueExW(k, L"DoNotShowEula", 0, REG_BINARY, &one, 1) == ERROR_SUCCESS;
    }
    RegCloseKey(k);
    snprintf(reply, size, "%s", changed ? "1" : "0");
    return 1;
}

}  // namespace buildsys

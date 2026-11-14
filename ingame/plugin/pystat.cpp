// A file's size and modification time as Python's os.stat gives them on Windows (posixmodule.c: the FILETIME split
// into seconds and nanoseconds, st_mtime = sec + nsec * 1e-9), the time as repr() writes the float - so a stamp the
// app wrote into library.json compares equal.
//
//   cj_py_stat(path) -> "<size> <mtime repr>"
#include "pystat.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <charconv>
#include <stdio.h>
#include <string>

namespace pystat {
namespace {

std::wstring Wide(const char* s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

// float.__repr__: the shortest digits that read back the same, fixed between 1e-4 and 1e16 (else e+XX)
std::string Repr(double v) {
    char buf[64];
    auto r = std::to_chars(buf, buf + sizeof(buf), v, std::chars_format::general);
    std::string s(buf, r.ptr);
    double a = v < 0 ? -v : v;
    if (a >= 1e-4 && a < 1e16) {
        auto f = std::to_chars(buf, buf + sizeof(buf), v, std::chars_format::fixed);
        s.assign(buf, f.ptr);
        if (s.find('.') == std::string::npos) s += ".0";
    }
    return s;
}

}  // namespace

int Stat(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) { snprintf(reply, size, "cj_py_stat(path)"); return 0; }
    WIN32_FILE_ATTRIBUTE_DATA a;
    if (!GetFileAttributesExW(Wide(argv[0]).c_str(), GetFileExInfoStandard, &a)) {
        snprintf(reply, size, "cj_py_stat: no file %s", argv[0]);
        return 0;
    }
    ULARGE_INTEGER t;
    t.LowPart = a.ftLastWriteTime.dwLowDateTime;
    t.HighPart = a.ftLastWriteTime.dwHighDateTime;
    const long long in = static_cast<long long>(t.QuadPart);
    const int nsec = static_cast<int>(in % 10000000) * 100;           // (FILE_TIME_to_time_t_nsec)
    const long long sec = in / 10000000 - 11644473600LL;
    const double mtime = static_cast<double>(sec) + nsec * 1e-9;     // (fill_time)
    const unsigned long long bytes = (static_cast<unsigned long long>(a.nFileSizeHigh) << 32) | a.nFileSizeLow;
    snprintf(reply, size, "%llu %s", bytes, Repr(mtime).c_str());
    return 1;
}

}  // namespace pystat

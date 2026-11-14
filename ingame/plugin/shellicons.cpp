// Windows' own icons as Qt 6.11.2 takes them (qwindowstheme.cpp, qpixmap_win.cpp), written as a PNG for the Lua UI:
// a file's or folder's icon (QWindowsFileIconEngine::filePixmap: SHGetFileInfo, small up to SM_CXSMICON, else large)
// and the standard pixmaps of the file dialog and the message boxes (QWindowsTheme::standardPixmap: a stock icon by
// SHDefExtractIcon at the size asked, else shell32's resource, else LoadIcon). The icon into a 32-bit DIB with
// DrawIconEx (QImage::fromHICON: its mask where it has no alpha), premultiplied as Qt keeps it; the PNG straight.
//
//   cj_shell_icon("file", path, size, out)    the file's icon; a path that does not exist: a plain file's
//   cj_shell_icon("std", name, size, out)     computer, desktop, home, trash, dir, dir_open, file, drive_hd, drive_cd,
//                                             drive_dvd, drive_net, drive_fd, new_folder, information, warning,
//                                             critical, question
//   -> "ok <w> <h>"
#include "shellicons.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <shellapi.h>
#include <shlobj.h>

#include <stdio.h>
#include <string.h>

#include <string>
#include <vector>

#include "stb_image_write.h"

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "user32.lib")

namespace shellicons {
namespace {

std::wstring Wide(const std::string& s) {
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
    return w;
}

// QImage::fromHICON: w and h from the hotspot, the icon drawn into a bottom-up 32-bit DIB section, read back top-down
// (getDiBits); no alpha anywhere: the mask decides (0 or opaque)
bool FromHicon(HICON icon, int* pw, int* ph, std::vector<unsigned char>* bgra) {
    ICONINFO info;
    if (!GetIconInfo(icon, &info)) return false;
    const int w = static_cast<int>(info.xHotspot) * 2;
    const int h = static_cast<int>(info.yHotspot) * 2;
    HDC screen = GetDC(nullptr);
    HDC hdc = CreateCompatibleDC(screen);
    ReleaseDC(nullptr, screen);
    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = h;               // (Qt: topToBottom false for the section)
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP dib = CreateDIBSection(hdc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ old = SelectObject(hdc, dib);
    auto read = [&](std::vector<unsigned char>* out) {
        // getDiBits(..., topToBottom = true): a negative height, rows from the top
        BITMAPINFO rb;
        memset(&rb, 0, sizeof(rb));
        rb.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        rb.bmiHeader.biWidth = w;
        rb.bmiHeader.biHeight = -h;
        rb.bmiHeader.biPlanes = 1;
        rb.bmiHeader.biBitCount = 32;
        rb.bmiHeader.biCompression = BI_RGB;
        out->assign(static_cast<size_t>(w) * h * 4, 0);
        return GetDIBits(hdc, dib, 0, h, out->data(), &rb, DIB_RGB_COLORS) != 0;
    };
    DrawIconEx(hdc, 0, 0, icon, w, h, 0, nullptr, DI_NORMAL);
    bool ok = read(bgra);
    if (ok) {
        bool alpha = false;
        for (size_t i = 3; i < bgra->size(); i += 4) if ((*bgra)[i]) { alpha = true; break; }
        if (!alpha) {
            DrawIconEx(hdc, 0, 0, icon, w, h, 0, nullptr, DI_MASK);
            std::vector<unsigned char> mask;
            bool have = read(&mask);
            for (size_t i = 0; i < bgra->size(); i += 4) {
                if (have && mask[i + 2] != 0) { (*bgra)[i] = (*bgra)[i + 1] = (*bgra)[i + 2] = (*bgra)[i + 3] = 0; }
                else (*bgra)[i + 3] = 0xff;
            }
        }
    }
    DeleteObject(info.hbmMask);
    DeleteObject(info.hbmColor);
    SelectObject(hdc, old);
    DeleteObject(dib);
    DeleteDC(hdc);
    *pw = w;
    *ph = h;
    return ok;
}

// premultiplied BGRA (Qt's ARGB32_Premultiplied) -> straight RGBA as QImage::convertToFormat(ARGB32) gives it
// (qUnpremultiply: the inverse factor 0xff00ff / a, then rounded)
std::vector<unsigned char> Straight(const std::vector<unsigned char>& bgra) {
    std::vector<unsigned char> out(bgra.size());
    for (size_t i = 0; i < bgra.size(); i += 4) {
        unsigned a = bgra[i + 3];
        unsigned b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
        if (a == 0) { r = g = b = 0; }
        else if (a != 255) {
            const unsigned inv = 0xff00ffu / a;            // (qt_inv_premul_factor)
            r = (r * inv + 0x8000) >> 16;
            g = (g * inv + 0x8000) >> 16;
            b = (b * inv + 0x8000) >> 16;
        }
        out[i] = static_cast<unsigned char>(r);
        out[i + 1] = static_cast<unsigned char>(g);
        out[i + 2] = static_cast<unsigned char>(b);
        out[i + 3] = static_cast<unsigned char>(a);
    }
    return out;
}

std::string Write(HICON icon, const std::string& out) {
    int w = 0, h = 0;
    std::vector<unsigned char> bgra;
    if (!FromHicon(icon, &w, &h, &bgra) || w <= 0 || h <= 0) return "!no picture from the icon";
    std::vector<unsigned char> rgba = Straight(bgra);
    std::string png;
    stbi_write_png_to_func([](void* ctx, void* d, int len) { static_cast<std::string*>(ctx)->append(
                               static_cast<const char*>(d), len); }, &png, w, h, 4, rgba.data(), w * 4);
    if (png.empty()) return "!cannot make the PNG";
    HANDLE f = CreateFileW(Wide(out).c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return "!cannot write " + out;
    DWORD done = 0;
    BOOL wrote = WriteFile(f, png.data(), static_cast<DWORD>(png.size()), &done, nullptr);
    CloseHandle(f);
    if (!wrote || done != png.size()) return "!cannot write " + out;
    char buf[64];
    snprintf(buf, sizeof(buf), "ok %d %d", w, h);
    return buf;
}

std::string FileIcon(const std::string& path, int size, const std::string& out) {
    HRESULT co = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);   // (QComHelper)
    const int small_size = GetSystemMetrics(SM_CXSMICON);
    UINT flags = SHGFI_ICON | (size > small_size ? SHGFI_LARGEICON : SHGFI_SMALLICON) | SHGFI_SYSICONINDEX |
                 SHGFI_ADDOVERLAYS | SHGFI_OVERLAYINDEX;
    std::wstring wp = Wide(path);
    for (auto& c : wp) if (c == L'/') c = L'\\';
    DWORD attrs = 0;
    if (GetFileAttributesW(wp.c_str()) == INVALID_FILE_ATTRIBUTES) {
        flags |= SHGFI_USEFILEATTRIBUTES;
        attrs |= FILE_ATTRIBUTE_NORMAL;
    }
    SHFILEINFOW info;
    memset(&info, 0, sizeof(info));
    DWORD_PTR r = SHGetFileInfoW(wp.c_str(), attrs, &info, sizeof(info), flags);
    std::string answer = "!no icon for " + path;
    if (r && info.hIcon) {
        answer = Write(info.hIcon, out);
        DestroyIcon(info.hIcon);
    }
    if (SUCCEEDED(co)) CoUninitialize();
    return answer;
}

struct Std {
    const char* name;
    SHSTOCKICONID stock;
    int resource;
    int system;                  // (IDI_*: LoadIcon's system icons; 0 none)
};
const Std kStd[] = {
    {"drive_cd", SIID_DRIVECD, 12, 0},     {"drive_dvd", SIID_DRIVEDVD, 12, 0},
    {"drive_net", SIID_DRIVENET, 10, 0},   {"drive_hd", SIID_DRIVEFIXED, 9, 0},
    {"drive_fd", SIID_DRIVE35, 7, 0},      {"file", SIID_DOCNOASSOC, 1, 0},
    {"dir", SIID_FOLDER, 4, 0},            {"desktop", SIID_INVALID, 35, 0},
    {"computer", SIID_INVALID, 16, 0},     {"dir_open", SIID_FOLDEROPEN, 5, 0},
    {"new_folder", SIID_FOLDER, 319, 0},   {"home", SIID_INVALID, 235, 0},
    {"trash", SIID_RECYCLER, 191, 0},      {"information", SIID_INFO, -1, 32516},
    {"warning", SIID_WARNING, -1, 32515},  {"critical", SIID_ERROR, -1, 32513},
    {"question", SIID_HELP, -1, 32514},
};

std::string StdIcon(const std::string& name, int size, const std::string& out) {
    const Std* s = nullptr;
    for (const auto& e : kStd) if (name == e.name) s = &e;
    if (!s) return "!unknown icon " + name;
    if (s->stock != SIID_INVALID) {
        SHSTOCKICONINFO si;
        memset(&si, 0, sizeof(si));
        si.cbSize = sizeof(si);
        if (SHGetStockIconInfo(s->stock, SHGSI_ICONLOCATION, &si) == S_OK) {
            HICON icon = nullptr;
            if (SHDefExtractIconW(si.szPath, si.iIcon, 0, &icon, nullptr, static_cast<UINT>(size)) == S_OK && icon) {
                std::string answer = Write(icon, out);
                DestroyIcon(icon);
                if (answer.rfind("ok", 0) == 0) return answer;
            }
        }
    }
    if (s->resource != -1) {
        HMODULE shell32 = GetModuleHandleW(L"shell32.dll");
        if (!shell32) shell32 = LoadLibraryW(L"shell32.dll");
        HICON icon = static_cast<HICON>(LoadImageW(shell32, MAKEINTRESOURCEW(s->resource), IMAGE_ICON, size, size, 0));
        if (icon) {
            std::string answer = Write(icon, out);
            DestroyIcon(icon);
            if (answer.rfind("ok", 0) == 0) return answer;
        }
    }
    if (s->system) {
        HICON icon = LoadIconW(nullptr, MAKEINTRESOURCEW(s->system));
        if (icon) {
            std::string answer = Write(icon, out);
            DestroyIcon(icon);
            return answer;
        }
    }
    return "!no icon " + name;
}

int Fail(char* reply, uint32_t size, const std::string& s) {
    snprintf(reply, size, "%s", s.c_str());
    return 0;
}

}  // namespace

int Icon(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 4) return Fail(reply, size, "cj_shell_icon(kind, what, size, out)");
    const std::string kind = argv[0];
    const int px = atoi(argv[2]);
    std::string answer;
    if (kind == "file") answer = FileIcon(argv[1], px, argv[3]);
    else if (kind == "std") answer = StdIcon(argv[1], px, argv[3]);
    else answer = "!kind is file or std";
    if (!answer.empty() && answer[0] == '!') return Fail(reply, size, "cj_shell_icon: " + answer.substr(1));
    snprintf(reply, size, "%s", answer.c_str());
    return 1;
}

}  // namespace shellicons

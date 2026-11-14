// The Asset Browser's folder pictures (catalog_view.mosaic): up to four pictures in a 2 x 2 mosaic, made as the app's
// Pillow makes them - each opened as RGBA, Image.thumbnail((cell, cell)) (for RGBA: premultiplied, resampled with
// the bicubic filter of Pillow's Resample.c, no reducing step - resize() calls itself without reducing_gap for
// RGBA - then back), pasted with its own alpha as the mask onto a transparent canvas (Paste.c: every band blended,
// alpha too), written as a PNG. Resample.c's arithmetic below is Pillow 12.2.0's (HPND, see THIRD_PARTY_NOTICES.txt).
//
//   cj_mosaic(out, size, file ...)          -> "ok" | "none"       made now
//   cj_mosaic_async(out, size, file ...)    -> "queued"            on cj_core's thread; cj_mosaic_status(out)
//   cj_mosaic_status(out)                   -> "busy" | "ok" | "none" | "!why"   (once done, given once)
//   cj_thumb(out, size, mode, file ...)     -> "ok" | "none"       an Asset Browser picture as the app makes it
//   cj_thumb_async(out, size, mode, file ...) -> "queued"          the same on the thread; its answer: cj_mosaic_status
#include "mosaic.h"

#include "stb_image.h"
#include "stb_image_write.h"

#include <windows.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace mosaic {
namespace {

struct Img {
    int w = 0, h = 0;
    std::vector<unsigned char> px;      // RGBA, w * h * 4
};

std::wstring Wide(const std::string& s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
    return w;
}
bool Load(const std::string& path, Img& im) {
    FILE* f = _wfopen(Wide(path).c_str(), L"rb");
    if (!f) return false;
    int w = 0, h = 0, n = 0;
    unsigned char* p = stbi_load_from_file(f, &w, &h, &n, 4);
    fclose(f);
    if (!p) return false;
    im.w = w;
    im.h = h;
    im.px.assign(p, p + static_cast<size_t>(w) * h * 4);
    stbi_image_free(p);
    return true;
}

// --- Pillow's ImagingUtils.h / Convert.c
inline unsigned Shift255(unsigned a) { return ((a >> 8) + a) >> 8; }
inline unsigned MulDiv255(unsigned a, unsigned b) { return Shift255(a * b + 128); }
inline unsigned Div255(unsigned a) { return Shift255(a + 128); }
inline unsigned Blend(unsigned mask, unsigned in1, unsigned in2) { return Div255(in1 * (255 - mask) + in2 * mask); }
inline int Clip8(int v) { return v <= 0 ? 0 : v < 256 ? v : 255; }
void Premultiply(Img& im) {         // rgbA2rgba
    for (size_t i = 0; i < im.px.size(); i += 4) {
        unsigned a = im.px[i + 3];
        for (int c = 0; c < 3; ++c) im.px[i + c] = static_cast<unsigned char>(MulDiv255(im.px[i + c], a));
    }
}
void Unpremultiply(Img& im) {       // rgba2rgbA
    for (size_t i = 0; i < im.px.size(); i += 4) {
        unsigned a = im.px[i + 3];
        if (a == 255 || a == 0) continue;
        for (int c = 0; c < 3; ++c) im.px[i + c] = static_cast<unsigned char>(Clip8((255 * im.px[i + c]) / a));
    }
}

// --- Pillow's Resample.c, the bicubic filter and the 8-bit passes
double Bicubic(double x) {
    const double a = -0.5;
    if (x < 0.0) x = -x;
    if (x < 1.0) return ((a + 2.0) * x - (a + 3.0)) * x * x + 1;
    if (x < 2.0) return (((x - 5) * x + 8) * x - 4) * a;
    return 0.0;
}
const int PRECISION_BITS = 32 - 8 - 2;
inline unsigned char Clip8Fixed(int in) {   // clip8: the lookup table of -640 .. 639 is this
    int v = in >> PRECISION_BITS;
    return static_cast<unsigned char>(v <= 0 ? 0 : v >= 255 ? 255 : v);
}
// the lanczos filter (truncated sinc, support 3): Image.resize(..., LANCZOS), the app's REDkit pictures
double Sinc(double x) {
    if (x == 0.0) return 1.0;
    x = x * 3.14159265358979323846;
    return sin(x) / x;
}
double Lanczos(double x) {
    if (-3.0 <= x && x < 3.0) return Sinc(x) * Sinc(x / 3);
    return 0.0;
}
struct Filter {
    double (*f)(double);
    double support;
};
const Filter BICUBIC = {Bicubic, 2.0}, LANCZOS = {Lanczos, 3.0};
int PrecomputeCoeffs(int in_size, float in0, float in1, int out_size, std::vector<int>& bounds,
                     std::vector<double>& kk, const Filter& filter) {
    double filterscale, scale;
    filterscale = scale = static_cast<double>(in1 - in0) / out_size;
    if (filterscale < 1.0) filterscale = 1.0;
    double support = filter.support * filterscale;
    int ksize = static_cast<int>(ceil(support)) * 2 + 1;
    kk.assign(static_cast<size_t>(out_size) * ksize, 0.0);
    bounds.assign(static_cast<size_t>(out_size) * 2, 0);
    for (int xx = 0; xx < out_size; ++xx) {
        double center = in0 + (xx + 0.5) * scale;
        double ww = 0.0;
        double ss = 1.0 / filterscale;
        int xmin = static_cast<int>(center - support + 0.5);
        if (xmin < 0) xmin = 0;
        int xmax = static_cast<int>(center + support + 0.5);
        if (xmax > in_size) xmax = in_size;
        xmax -= xmin;
        double* k = &kk[static_cast<size_t>(xx) * ksize];
        for (int x = 0; x < xmax; ++x) {
            double w = filter.f((x + xmin - center + 0.5) * ss);
            k[x] = w;
            ww += w;
        }
        for (int x = 0; x < xmax; ++x) if (ww != 0.0) k[x] /= ww;
        bounds[xx * 2] = xmin;
        bounds[xx * 2 + 1] = xmax;
    }
    return ksize;
}
std::vector<int> Normalize(const std::vector<double>& pre) {
    std::vector<int> kk(pre.size());
    for (size_t x = 0; x < pre.size(); ++x)
        kk[x] = pre[x] < 0 ? static_cast<int>(-0.5 + pre[x] * (1 << PRECISION_BITS))
                           : static_cast<int>(0.5 + pre[x] * (1 << PRECISION_BITS));
    return kk;
}
// ImagingResample (box (0, 0, w, h)) of a 4-band image, bicubic unless told
Img Resample(const Img& in, int xsize, int ysize, const Filter& filter = BICUBIC) {
    float box[4] = {0, 0, static_cast<float>(in.w), static_cast<float>(in.h)};
    bool need_h = xsize != in.w || box[0] || box[2] != xsize;
    bool need_v = ysize != in.h || box[1] || box[3] != ysize;
    std::vector<int> bh, bv;
    std::vector<double> kh, kv;
    int ksh = PrecomputeCoeffs(in.w, box[0], box[2], xsize, bh, kh, filter);
    int ksv = PrecomputeCoeffs(in.h, box[1], box[3], ysize, bv, kv, filter);
    int ybox_first = bv[0];
    int ybox_last = bv[ysize * 2 - 2] + bv[ysize * 2 - 1];
    Img cur = in;
    if (need_h) {
        for (int i = 0; i < ysize; ++i) bv[i * 2] -= ybox_first;
        std::vector<int> k = Normalize(kh);
        Img t;
        t.w = xsize;
        t.h = ybox_last - ybox_first;
        t.px.assign(static_cast<size_t>(t.w) * t.h * 4, 0);
        for (int yy = 0; yy < t.h; ++yy) {
            const unsigned char* row = &in.px[static_cast<size_t>(yy + ybox_first) * in.w * 4];
            for (int xx = 0; xx < xsize; ++xx) {
                int xmin = bh[xx * 2], xmax = bh[xx * 2 + 1];
                const int* kx = &k[static_cast<size_t>(xx) * ksh];
                int s[4];
                for (int c = 0; c < 4; ++c) s[c] = 1 << (PRECISION_BITS - 1);
                for (int x = 0; x < xmax; ++x)
                    for (int c = 0; c < 4; ++c) s[c] += row[(x + xmin) * 4 + c] * kx[x];
                unsigned char* o = &t.px[(static_cast<size_t>(yy) * xsize + xx) * 4];
                for (int c = 0; c < 4; ++c) o[c] = Clip8Fixed(s[c]);
            }
        }
        cur = std::move(t);
    }
    if (need_v) {
        std::vector<int> k = Normalize(kv);
        Img o;
        o.w = cur.w;
        o.h = ysize;
        o.px.assign(static_cast<size_t>(o.w) * o.h * 4, 0);
        for (int yy = 0; yy < ysize; ++yy) {
            const int* ky = &k[static_cast<size_t>(yy) * ksv];
            int ymin = bv[yy * 2], ymax = bv[yy * 2 + 1];
            for (int xx = 0; xx < cur.w; ++xx) {
                int s[4];
                for (int c = 0; c < 4; ++c) s[c] = 1 << (PRECISION_BITS - 1);
                for (int y = 0; y < ymax; ++y) {
                    const unsigned char* p = &cur.px[(static_cast<size_t>(y + ymin) * cur.w + xx) * 4];
                    for (int c = 0; c < 4; ++c) s[c] += p[c] * ky[y];
                }
                unsigned char* d = &o.px[(static_cast<size_t>(yy) * o.w + xx) * 4];
                for (int c = 0; c < 4; ++c) d[c] = Clip8Fixed(s[c]);
            }
        }
        cur = std::move(o);
    }
    return cur;
}

// Image.thumbnail((size, size)): the size kept to the picture's aspect as Pillow rounds it
bool ThumbSize(int w, int h, int x, int y, int* ox, int* oy) {
    if (x >= w && y >= h) return false;
    double aspect = static_cast<double>(w) / h;
    auto pick = [](double number, auto key) {
        double lo = floor(number), hi = ceil(number);
        double best = key(lo) <= key(hi) ? lo : hi;          // (min(floor, ceil, key=...): the first of equals)
        return (std::max)(static_cast<int>(best), 1);
    };
    if (static_cast<double>(x) / y >= aspect) {
        x = pick(y * aspect, [&](double n) { return fabs(aspect - n / y); });
    } else {
        y = pick(x / aspect, [&](double n) { return n == 0 ? 0.0 : fabs(aspect - x / n); });
    }
    *ox = x;
    *oy = y;
    return true;
}
void Thumbnail(Img& im, int cell) {
    int tw, th;
    if (!ThumbSize(im.w, im.h, cell, cell, &tw, &th)) return;
    if (tw == im.w && th == im.h) return;
    Premultiply(im);
    im = Resample(im, tw, th);
    Unpremultiply(im);
}

bool WriteAll(const std::string& path, const void* data, size_t n) {
    std::wstring w = Wide(path);
    // (the folder first: thumbs\folders\<size>\)
    for (size_t i = 3; i < w.size(); ++i)
        if (w[i] == L'\\' || w[i] == L'/') CreateDirectoryW(w.substr(0, i).c_str(), nullptr);
    std::wstring tmp = w + L".tmp";
    FILE* o = _wfopen(tmp.c_str(), L"wb");
    if (!o) return false;
    size_t wrote = n ? fwrite(data, 1, n, o) : 0;
    fclose(o);
    if (wrote != n || !MoveFileExW(tmp.c_str(), w.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(tmp.c_str());
        return false;
    }
    return true;
}

// catalog_view.mosaic -> "ok", "none" (no pictures) or "!why"
std::string Make(const std::string& out, int size, const std::vector<std::string>& files) {
    std::vector<Img> pics;
    for (size_t i = 0; i < files.size() && pics.size() < 4; ++i) {
        Img im;
        if (!Load(files[i], im)) return "!cannot read " + files[i];
        pics.push_back(std::move(im));
    }
    if (pics.empty()) return "none";
    int gap = (std::max)(2, size / 48);
    int cell = (size - gap) / 2;
    Img canvas;
    canvas.w = canvas.h = size;
    canvas.px.assign(static_cast<size_t>(size) * size * 4, 0);
    int n = static_cast<int>(pics.size());
    for (int k = 0; k < n; ++k) {
        Img& im = pics[k];
        Thumbnail(im, cell);
        int cx = (k % 2) * (cell + gap), cy = (k / 2) * (cell + gap);
        if (n == 1) cx = cy = (size - cell) / 2;                 // one: in the middle
        else if (n == 2) cy = (size - cell) / 2;                 // two: side by side, in the middle
        else if (n == 3 && k == 2) cx = (size - cell) / 2;       // three: the third in the middle below
        int dx = cx + (cell - im.w) / 2, dy = cy + (cell - im.h) / 2;
        // (Python's // floors; these are not negative)
        for (int y = 0; y < im.h; ++y) {
            int ty = dy + y;
            if (ty < 0 || ty >= size) continue;
            for (int x = 0; x < im.w; ++x) {
                int tx = dx + x;
                if (tx < 0 || tx >= size) continue;
                const unsigned char* s = &im.px[(static_cast<size_t>(y) * im.w + x) * 4];
                unsigned char* d = &canvas.px[(static_cast<size_t>(ty) * size + tx) * 4];
                unsigned a = s[3];
                for (int c = 0; c < 4; ++c) d[c] = static_cast<unsigned char>(Blend(a, d[c], s[c]));
            }
        }
    }
    std::string png;
    stbi_write_png_to_func([](void* ctx, void* d, int len) { static_cast<std::string*>(ctx)->append(
                               static_cast<const char*>(d), len); }, &png, size, size, 4, canvas.px.data(), size * 4);
    if (png.empty() || !WriteAll(out, png.data(), png.size())) return "!cannot write " + out;
    return "ok";
}

// --- the app's pictures of the Asset Browser (assets.thumbnail): REDkit's picture of a template or mesh
// (r4data\thumbnails\<path>.thmb, a CR2W around a PNG) opened as RGBA, Image.resize((size, size), LANCZOS) when it
// is bigger (RGBA: premultiplied around it); a blank one (REDkit drew only the sky) gives way to the first of up to
// six of its meshes that is not. A decal's texture (cj_tex_image at twice the size) is made smaller in its file as
// Image.thumbnail does (mode "png").
bool Redkit(const std::string& path, int size, Img& im) {
    if (path.empty()) return false;
    FILE* f = _wfopen(Wide(path).c_str(), L"rb");
    if (!f) return false;
    std::string data;
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) data.append(buf, n);
    fclose(f);
    size_t i = data.find("\x89PNG");
    if (i == std::string::npos) return false;
    int w = 0, h = 0, c = 0;
    unsigned char* p = stbi_load_from_memory(reinterpret_cast<const unsigned char*>(data.data() + i),
                                             static_cast<int>(data.size() - i), &w, &h, &c, 4);
    if (!p) return false;
    im.w = w;
    im.h = h;
    im.px.assign(p, p + static_cast<size_t>(w) * h * 4);
    stbi_image_free(p);
    if (size < im.w) {
        Premultiply(im);
        im = Resample(im, size, size, LANCZOS);
        Unpremultiply(im);
    }
    return true;
}
// assets._blank: im.convert("RGB").resize((32, 32)) (bicubic; its alpha left out), over 90 % near the colour at 2, 2
bool Blank(const Img& im) {
    Img s = (im.w == 32 && im.h == 32) ? im : Resample(im, 32, 32);
    const unsigned char* sky = &s.px[(2 * 32 + 2) * 4];
    int alike = 0;
    for (int k = 0; k < 32 * 32; ++k) {
        const unsigned char* q = &s.px[k * 4];
        if (abs(q[0] - sky[0]) + abs(q[1] - sky[1]) + abs(q[2] - sky[2]) < 30) ++alike;
    }
    return alike > 0.9 * 1024;
}
std::string Save(const std::string& out, const Img& im) {
    std::string png;
    stbi_write_png_to_func([](void* ctx, void* d, int len) { static_cast<std::string*>(ctx)->append(
                               static_cast<const char*>(d), len); }, &png, im.w, im.h, 4, im.px.data(), im.w * 4);
    if (png.empty() || !WriteAll(out, png.data(), png.size())) return "!cannot write " + out;
    return "ok";
}
// mode "thmb": files[0]'s picture; "thmb+": and the meshes after it when that one is blank or missing; "png": the
// picture in out made smaller -> "ok", "none" or "!why"
std::string MakeThumb(const std::string& out, int size, const std::string& mode, const std::vector<std::string>& files) {
    Img im;
    if (mode == "png") {
        if (!Load(out, im)) return "none";
        Thumbnail(im, size);
        return Save(out, im);
    }
    bool have = !files.empty() && Redkit(files[0], size, im);
    if (mode == "thmb+" && (!have || Blank(im))) {
        for (size_t k = 1; k < files.size() && k <= 6; ++k) {
            Img alt;
            if (Redkit(files[k], size, alt) && !Blank(alt)) {
                im = std::move(alt);
                have = true;
                break;
            }
        }
    }
    if (!have) return "none";
    return Save(out, im);
}

// the worker (one thread: jobs in, answers by their file)
struct Job {
    std::string out;
    int size;
    std::vector<std::string> files;
    std::string mode;                   // "": a mosaic; else cj_thumb's
};
std::mutex g_mx;
std::condition_variable g_cv;
std::deque<Job> g_q;
std::unordered_map<std::string, std::string> g_done;
std::thread* g_worker = nullptr;    // (never destroyed: Windows ends it with the process)
void Work() {
    for (;;) {
        Job j;
        {
            std::unique_lock<std::mutex> lk(g_mx);
            g_cv.wait(lk, [] { return !g_q.empty(); });
            j = g_q.front();
            g_q.pop_front();
        }
        std::string answer = j.mode.empty() ? Make(j.out, j.size, j.files) : MakeThumb(j.out, j.size, j.mode, j.files);
        std::lock_guard<std::mutex> lk(g_mx);
        g_done[j.out] = answer;
    }
}

int Fail(char* reply, uint32_t size, const std::string& s) {
    snprintf(reply, size, "%s", s.c_str());
    return 0;
}

}  // namespace

int Now(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_mosaic(out, size, file ...)");
    std::vector<std::string> files(argv + 2, argv + argc);
    std::string answer = Make(argv[0], atoi(argv[1]), files);
    if (!answer.empty() && answer[0] == '!') return Fail(reply, size, "cj_mosaic: " + answer.substr(1));
    snprintf(reply, size, "%s", answer.c_str());
    return 1;
}

int Async(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_mosaic_async(out, size, file ...)");
    {
        std::lock_guard<std::mutex> lk(g_mx);
        if (!g_worker) g_worker = new std::thread(Work);
        g_done.erase(argv[0]);
        g_q.push_back({argv[0], atoi(argv[1]), std::vector<std::string>(argv + 2, argv + argc), ""});
    }
    g_cv.notify_one();
    snprintf(reply, size, "queued");
    return 1;
}

int Status(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_mosaic_status(out)");
    std::lock_guard<std::mutex> lk(g_mx);
    auto it = g_done.find(argv[0]);
    if (it == g_done.end()) {
        snprintf(reply, size, "busy");
        return 1;
    }
    snprintf(reply, size, "%s", it->second.c_str());
    g_done.erase(it);
    return 1;
}

int Thumb(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 3) return Fail(reply, size, "cj_thumb(out, size, mode, file ...)");
    std::string answer = MakeThumb(argv[0], atoi(argv[1]), argv[2], std::vector<std::string>(argv + 3, argv + argc));
    if (!answer.empty() && answer[0] == '!') return Fail(reply, size, "cj_thumb: " + answer.substr(1));
    snprintf(reply, size, "%s", answer.c_str());
    return 1;
}

int ThumbAsync(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 3) return Fail(reply, size, "cj_thumb_async(out, size, mode, file ...)");
    {
        std::lock_guard<std::mutex> lk(g_mx);
        if (!g_worker) g_worker = new std::thread(Work);
        g_done.erase(argv[0]);
        g_q.push_back({argv[0], atoi(argv[1]), std::vector<std::string>(argv + 3, argv + argc), argv[2]});
    }
    g_cv.notify_one();
    snprintf(reply, size, "queued");
    return 1;
}

}  // namespace mosaic

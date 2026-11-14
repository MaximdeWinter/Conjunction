// Qt's smooth scaling (QImage::smoothScaled -> qSmoothScaleImage), for pictures that look as the app draws them:
// QPixmap.scaled(..., SmoothTransformation). Taken from Qt 6.11.2's src/gui/painting/qimagescale.cpp (BSD-2-Clause
// AND Imlib2: see the notice below), on plain buffers instead of QImage, only the 32-bit paths (ARGB32_Premultiplied
// and RGB32) and without its threads (the rows do not depend on each other: the same pixels). Qt's SSE4.1 copies
// (qimagescale_sse4.cpp) do the same integer sums as these; the four-pixel blend for scaling up is written here after
// Qt's SSE2 one (top and bottom first, then left and right), which is the one an x64 build of Qt runs.
//
// Copyright (C) 2016 The Qt Company Ltd.
// Copyright (C) 2004, 2005 Daniel M. Duley., (C) Carsten Haitzler and various contributors., (C) Willem Monsuwe
//
// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
// following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the
//    following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
//    following disclaimer in the documentation and/or other materials provided with the distribution.
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
// THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// Imlib2 is (C) Carsten Haitzler and various contributors. The MMX code is by Willem Monsuwe. All other modifications
// are (C) Daniel M. Duley.
#include "qtscale.h"

#include <stdint.h>
#include <stdlib.h>
#include <vector>

namespace qtscale {
namespace {
typedef unsigned int uint;
inline int qRed(uint p) { return (p >> 16) & 0xff; }
inline int qGreen(uint p) { return (p >> 8) & 0xff; }
inline int qBlue(uint p) { return p & 0xff; }
inline int qAlpha(uint p) { return p >> 24; }
inline uint qRgba(int r, int g, int b, int a) {
    return ((a & 0xffu) << 24) | ((r & 0xffu) << 16) | ((g & 0xffu) << 8) | (b & 0xffu);
}
inline uint qRgb(int r, int g, int b) { return 0xff000000u | ((r & 0xffu) << 16) | ((g & 0xffu) << 8) | (b & 0xffu); }
inline long long qMax0(long long v) { return v < 0 ? 0 : v; }

// two pixels by 256ths, each channel (x * a + y * b) >> 8 (a + b = 256)
inline uint mix256(uint x, uint a, uint y, uint b) {
    uint out = 0;
    for (int s = 0; s < 32; s += 8) out |= ((((x >> s) & 0xff) * a + ((y >> s) & 0xff) * b) >> 8) << s;
    return out;
}
// four pixels: top and bottom first, then left and right (Qt's SSE2 order)
inline uint mix4(const uint* t, const uint* b, uint dx, uint dy) {
    uint out = 0;
    for (int s = 0; s < 32; s += 8) {
        uint l = ((((t[0] >> s) & 0xff) * (256 - dy) + ((b[0] >> s) & 0xff) * dy) >> 8);
        uint r = ((((t[1] >> s) & 0xff) * (256 - dy) + ((b[1] >> s) & 0xff) * dy) >> 8);
        uint v = (l * (256 - dx) + r * dx) >> 8;
        out |= (v > 255 ? 255 : v) << s;
    }
    return out;
}

struct Info {
    std::vector<int> xpoints, xapoints, yapoints;
    std::vector<const uint*> ypoints;
    int xup_yup = 0;
};

std::vector<const uint*> CalcYPoints(const uint* src, int sw, int sh, int dh) {
    std::vector<const uint*> p(dh + 1);
    int up = dh >= sh;
    long long val = up ? 0x8000LL * sh / dh - 0x8000 : 0;
    long long inc = (static_cast<long long>(sh) << 16) / dh;
    for (int i = 0; i < dh; i++) {
        p[i] = src + qMax0(val >> 16) * sw;
        val += inc;
    }
    return p;
}

std::vector<int> CalcXPoints(int sw, int dw) {
    std::vector<int> p(dw + 1);
    int up = dw >= sw;
    long long val = up ? 0x8000LL * sw / dw - 0x8000 : 0;
    long long inc = (static_cast<long long>(sw) << 16) / dw;
    for (int i = 0; i < dw; i++) {
        p[i] = static_cast<int>(qMax0(val >> 16));
        val += inc;
    }
    return p;
}

std::vector<int> CalcApoints(int s, int d, int up) {
    std::vector<int> p(d);
    if (up) {
        long long val = 0x8000LL * s / d - 0x8000;
        long long inc = (static_cast<long long>(s) << 16) / d;
        for (int i = 0; i < d; i++) {
            int pos = static_cast<int>(val >> 16);
            if (pos < 0 || pos >= s - 1) p[i] = 0;
            else p[i] = static_cast<int>((val >> 8) - ((val >> 8) & 0xffffff00));
            val += inc;
        }
    } else {
        long long val = 0;
        long long inc = (static_cast<long long>(s) << 16) / d;
        int Cp = ((d << 14) + s - 1) / s;
        for (int i = 0; i < d; i++) {
            int ap = static_cast<int>(((0x10000 - (val & 0xffff)) * Cp) >> 16);
            p[i] = ap | (Cp << 16);
            val += inc;
        }
    }
    return p;
}

void ScaleUpXY(Info& isi, uint* dest, int dw, int dh, int sow) {
    for (int y = 0; y < dh; ++y) {
        const uint* sptr = isi.ypoints[y];
        uint* dptr = dest + y * dw;
        const int yap = isi.yapoints[y];
        for (int x = 0; x < dw; x++) {
            const uint* pix = sptr + isi.xpoints[x];
            const int xap = isi.xapoints[x];
            if (yap > 0) *dptr++ = xap > 0 ? mix4(pix, pix + sow, xap, yap) : mix256(pix[0], 256 - yap, pix[sow], yap);
            else *dptr++ = xap > 0 ? mix256(pix[0], 256 - xap, pix[1], xap) : pix[0];
        }
    }
}

inline void Helper(const uint* pix, int xyap, int Cxy, int step, int& r, int& g, int& b, int& a) {
    r = qRed(*pix) * xyap;
    g = qGreen(*pix) * xyap;
    b = qBlue(*pix) * xyap;
    a = qAlpha(*pix) * xyap;
    int j;
    for (j = (1 << 14) - xyap; j > Cxy; j -= Cxy) {
        pix += step;
        r += qRed(*pix) * Cxy;
        g += qGreen(*pix) * Cxy;
        b += qBlue(*pix) * Cxy;
        a += qAlpha(*pix) * Cxy;
    }
    pix += step;
    r += qRed(*pix) * j;
    g += qGreen(*pix) * j;
    b += qBlue(*pix) * j;
    a += qAlpha(*pix) * j;
}

void ScaleUpXDownY(Info& isi, uint* dest, int dw, int dh, int sow, bool rgb) {
    for (int y = 0; y < dh; ++y) {
        int Cy = isi.yapoints[y] >> 16;
        int yap = isi.yapoints[y] & 0xffff;
        uint* dptr = dest + y * dw;
        for (int x = 0; x < dw; x++) {
            const uint* sptr = isi.ypoints[y] + isi.xpoints[x];
            int r, g, b, a;
            Helper(sptr, yap, Cy, sow, r, g, b, a);
            int xap = isi.xapoints[x];
            if (xap > 0) {
                int rr, gg, bb, aa;
                Helper(sptr + 1, yap, Cy, sow, rr, gg, bb, aa);
                r = (r * (256 - xap) + rr * xap) >> 8;
                g = (g * (256 - xap) + gg * xap) >> 8;
                b = (b * (256 - xap) + bb * xap) >> 8;
                a = (a * (256 - xap) + aa * xap) >> 8;
            }
            *dptr++ = rgb ? qRgb(r >> 14, g >> 14, b >> 14) : qRgba(r >> 14, g >> 14, b >> 14, a >> 14);
        }
    }
}

void ScaleDownXUpY(Info& isi, uint* dest, int dw, int dh, int sow, bool rgb) {
    for (int y = 0; y < dh; ++y) {
        uint* dptr = dest + y * dw;
        for (int x = 0; x < dw; x++) {
            int Cx = isi.xapoints[x] >> 16;
            int xap = isi.xapoints[x] & 0xffff;
            const uint* sptr = isi.ypoints[y] + isi.xpoints[x];
            int r, g, b, a;
            Helper(sptr, xap, Cx, 1, r, g, b, a);
            int yap = isi.yapoints[y];
            if (yap > 0) {
                int rr, gg, bb, aa;
                Helper(sptr + sow, xap, Cx, 1, rr, gg, bb, aa);
                r = (r * (256 - yap) + rr * yap) >> 8;
                g = (g * (256 - yap) + gg * yap) >> 8;
                b = (b * (256 - yap) + bb * yap) >> 8;
                a = (a * (256 - yap) + aa * yap) >> 8;
            }
            *dptr++ = rgb ? qRgb(r >> 14, g >> 14, b >> 14) : qRgba(r >> 14, g >> 14, b >> 14, a >> 14);
        }
    }
}

void ScaleDownXY(Info& isi, uint* dest, int dw, int dh, int sow, bool rgb) {
    for (int y = 0; y < dh; ++y) {
        int Cy = isi.yapoints[y] >> 16;
        int yap = isi.yapoints[y] & 0xffff;
        uint* dptr = dest + y * dw;
        for (int x = 0; x < dw; x++) {
            int Cx = isi.xapoints[x] >> 16;
            int xap = isi.xapoints[x] & 0xffff;
            const uint* sptr = isi.ypoints[y] + isi.xpoints[x];
            int rx, gx, bx, ax;
            Helper(sptr, xap, Cx, 1, rx, gx, bx, ax);
            int r = (rx >> 4) * yap, g = (gx >> 4) * yap, b = (bx >> 4) * yap, a = (ax >> 4) * yap;
            int j;
            for (j = (1 << 14) - yap; j > Cy; j -= Cy) {
                sptr += sow;
                Helper(sptr, xap, Cx, 1, rx, gx, bx, ax);
                r += (rx >> 4) * Cy;
                g += (gx >> 4) * Cy;
                b += (bx >> 4) * Cy;
                a += (ax >> 4) * Cy;
            }
            sptr += sow;
            Helper(sptr, xap, Cx, 1, rx, gx, bx, ax);
            r += (rx >> 4) * j;
            g += (gx >> 4) * j;
            b += (bx >> 4) * j;
            a += (ax >> 4) * j;
            *dptr++ = rgb ? qRgb(r >> 24, g >> 24, b >> 24) : qRgba(r >> 24, g >> 24, b >> 24, a >> 24);
        }
    }
}
}  // namespace

// qSmoothScaleImage: src w x h (0xAARRGGBB, premultiplied when `alpha`, else RGB32 with alpha 0xff) -> dest dw x dh
bool SmoothScale(const uint32_t* src, int w, int h, uint32_t* dest, int dw, int dh, bool alpha) {
    if (!src || w <= 0 || h <= 0 || dw <= 0 || dh <= 0) return false;
    Info isi;
    // (scw = dw * w / sw with sw = w: dw)
    isi.xup_yup = (dw >= w) + ((dh >= h) << 1);
    isi.xpoints = CalcXPoints(w, dw);
    isi.ypoints = CalcYPoints(reinterpret_cast<const uint*>(src), w, h, dh);
    isi.xapoints = CalcApoints(w, dw, isi.xup_yup & 1);
    isi.yapoints = CalcApoints(h, dh, isi.xup_yup & 2);
    uint* d = reinterpret_cast<uint*>(dest);
    bool rgb = !alpha;
    if (isi.xup_yup == 3) ScaleUpXY(isi, d, dw, dh, w);
    else if (isi.xup_yup == 1) ScaleUpXDownY(isi, d, dw, dh, w, rgb);
    else if (isi.xup_yup == 2) ScaleDownXUpY(isi, d, dw, dh, w, rgb);
    else ScaleDownXY(isi, d, dw, dh, w, rgb);
    return true;
}
}  // namespace qtscale

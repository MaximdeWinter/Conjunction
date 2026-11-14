// Qt's smooth scaling on plain buffers (qtscale.cpp: qSmoothScaleImage of Qt 6.11.2, BSD-2-Clause AND Imlib2)
#pragma once
#include <stdint.h>

namespace qtscale {
// src w x h -> dest dw x dh, pixels 0xAARRGGBB (premultiplied when alpha; else RGB32, alpha 0xff)
bool SmoothScale(const uint32_t* src, int w, int h, uint32_t* dest, int dw, int dh, bool alpha);
}

// cj_qt: Qt's own painter for Conjunction's views in the game (a TW3SE plugin, tw3se\plugins\cj_qt.dll). What the app
// draws itself with QPainter - the Asset Browser's tiles, the quest graph, the dialogue cards - is drawn here by the
// same Qt (6.11.2, the app's) into a picture: the same pixels by construction. Text stays w3.ui's (drawn over it).
// Qt is LGPL-3.0: its DLLs (Qt6Core, Qt6Gui) lie beside this one in tw3se\plugins\cj_qt\ and can be replaced by any
// build of the same version; they load on the first picture (delay-loaded), so a game without them only lacks these.
//
// Lua (w3.plugin.<name>):
//   cj_qt_paint(out.png, w, h, commands) -> "w\th"     a w x h picture, transparent, the commands one per line:
//     fill RRGGBBAA                  the whole picture
//     aa 0|1                         QPainter::Antialiasing
//     pen RRGGBBAA width [cap join style]  QPen (width as Qt takes it: 0 = cosmetic; Qt's enums: cap, join, the
//                                    line's style - 2 a dashed line); nopen
//     brush RRGGBBAA                 nobrush
//     rect x y w h                   drawRect(QRect) - ints;  rectf x y w h: drawRect(QRectF)
//     rrect x y w h rx ry            drawRoundedRect(QRect, rx, ry);  rrectf ...: with a QRectF
//     poly x y x y ...               drawPolygon(QPolygon);  polyf ...: QPolygonF
//     line x1 y1 x2 y2               drawLine (ints);  linef ...: QLineF
//     ellipse x y w h                drawEllipse(QRect);  ellipsef ...: QRectF
//     image x y w h file             the picture file drawn at x y; with w h (not 0 0) first scaled to that size as
//                                    QPixmap.scaled(w, h, IgnoreAspectRatio, SmoothTransformation) does (the file
//                                    is the rest of the line: a path may have spaces)
//     polylinef x y x y ...          drawPolyline(QPolygonF)
//     font pointsize bold            the painter's font (the application's) at that point size, bold 0|1
//     text x y text                  drawText(QPointF, text): its baseline at y (the text is the rest of the line;
//                                    text needs Qt's application: cj_qt_gl_start first)
//     glyph RRGGBBAA x y w h px hex  an icon font's sign (Segoe Fluent Icons) as WinFontIconEngine paints it;
//                                    glyphpt: at a point size
//     imagefast x y w h file         the picture into the box unsmoothed (drawPixmap(rect) without the hint);
//                                    imagesmooth: with SmoothPixmapTransform
//     save / restore
//   (QGraphicsView's: the quest graph)
//     view m11 hx vy                 the view's transform (QGraphicsView: scale m11, scrolled by hx vy) as the world
//                                    transform; item px py: an item at px py on it; world: the view's again
//     path M x y L x y ... Z         drawPath(QPainterPath); clippath ...: setClipPath
//     fillrectf x y w h RRGGBBAA     fillRect(QRectF, QColor)
//     dash a b ...                   the pen's dash pattern
//     ellipsec cx cy rx ry           drawEllipse(QPointF, rx, ry)
//     gears x y w h turn RRGGBBAA    the build window's two rings with their teeth (build_view.Spheres)
//     fontpx px bold spacing         QFont("Segoe UI") at a pixel size, bold 0|1, letter spacing (absolute)
//     textrect x y w h flags text    drawText(QRectF, flags, text);  textelide x y w h flags width text: the text
//                                    first elided at the right to width (QFontMetrics of the font) - only what
//                                    comes before a 0x1f, the rest put after it; 0x1e: a line break
//     device W H X Y                 (the first line) painted as into a window W x H, the picture its part at X Y
//   cj_qt_paint(out.png, w, h, commands, "fast")  saved without compression (a picture made anew often)
//   cj_qt_advance(px, bold, spacing, text) -> width   QFontMetrics(QFont("Segoe UI" ...)).horizontalAdvance
//   cj_qt_font_height(px, bold) -> height              QFontMetrics(QFont("Segoe UI" ...)).height()
//   cj_qt_elide(pt, mode, width, text) -> text         QFontMetrics(QFont("Segoe UI", pt)).elidedText (a point size)
//   cj_qt_paint(out.png, w, h, commands, "sw sh") the same, saved scaled into sw x sh (aspect kept, smooth)
#define _USE_MATH_DEFINES  // (M_PI: the gears)
#include "tw3se/tw3se.h"

#include <windows.h>

#include <QtCore/QCollator>
#include <QtCore/QtMath>
#include <QtCore/QDateTime>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QLocale>
#include <QtCore/QMimeDatabase>
#include <QtCore/QRegularExpression>
#include <QtCore/QString>
#include <QtCore/QTimeZone>
#include <QtCore/QStringList>
#include <QtGui/QAbstractTextDocumentLayout>
#include <QtGui/QColor>
#include <QtGui/QImage>
#include <QtGui/QPainter>
#include <QtGui/QPainterPath>
#include <algorithm>
#include <cmath>
#include <QtGui/QFontMetrics>
#include <QtGui/QTransform>
#include <QtGui/QFont>
#include <QtGui/QPen>
#include <QtGui/QPalette>
#include <QtGui/QPolygon>
#include <QtGui/QTextDocument>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <string>
#include <vector>

using namespace Qt::StringLiterals;

#pragma comment(lib, "delayimp.lib")

namespace {
const TW3SE_Interface* g_api = nullptr;
bool g_qt = false;
std::string g_err;
std::wstring g_qt_dir;          // the folder Qt's DLLs came from (its platforms\ plugin too)

int Fail(char* reply, uint32_t size, const char* text) {
    snprintf(reply, size, "%s", text);
    return 0;
}

std::wstring Wide(const char* s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

// Qt6Core and Qt6Gui from tw3se\plugins\cj_qt\ (beside tw3se.dll's folder), before the first call into them: the
// delay-load helper then finds them loaded
bool LoadQt() {
    if (g_qt) return true;
    std::wstring dir;
    if (const wchar_t* env = _wgetenv(L"CJ_QT_DIR")) {         // (the lab's: a Qt of the same version)
        dir = std::wstring(env) + L"\\";
    } else {
        HMODULE tw = GetModuleHandleW(L"tw3se.dll");
        wchar_t path[MAX_PATH * 2] = {};
        if (!tw || !GetModuleFileNameW(tw, path, MAX_PATH * 2)) {
            g_err = "cj_qt: no tw3se.dll in the process";
            return false;
        }
        dir = path;
        dir = dir.substr(0, dir.find_last_of(L'\\')) + L"\\plugins\\cj_qt\\";
    }
    g_qt_dir = dir;
    for (const wchar_t* dll : {L"Qt6Core.dll", L"Qt6Gui.dll", L"Qt6OpenGL.dll"}) {
        if (!LoadLibraryExW((dir + dll).c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH)) {
            char why[64];
            snprintf(why, sizeof why, " (%ls: Windows error %lu)", dll, GetLastError());
            g_err = std::string("cj_qt: cannot load Qt from tw3se\\plugins\\cj_qt") + why;
            return false;
        }
    }
    g_qt = true;
    return true;
}

QColor Colour(const QString& hex) {
    bool ok = false;
    uint v = hex.toUInt(&ok, 16);
    return QColor((v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255);
}

}  // namespace
bool CjQtAppReady(int ms);     // cj_qt_gl.cpp: Qt's application up on its thread (text needs it)
bool CjQtAppStarting();        // ... on its way up: the other calls wait for it (two threads would race)
namespace {
// Qt loaded, and its application not half made on the other thread
bool QtUsable() {
    if (!LoadQt()) return false;
    if (CjQtAppStarting()) CjQtAppReady(15000);
    return true;
}

// the rest of a command line after its first n words (one space after each): a text as written, its spaces kept;
// 0x1e stands for a line break (the commands are one a line)
QString Rest(const QString& line, int n) {
    int at = 0;
    for (int k = 0; k < n && at >= 0; ++k) {
        at = line.indexOf(QLatin1Char(' '), at);
        if (at >= 0) ++at;
    }
    QString t = at >= 0 ? line.mid(at) : QString();
    t.replace(QChar(0x1e), QChar(0x0a));
    return t;
}

// graph_view._font: QFont("Segoe UI") at a pixel size, bold, letter spacing absolute
QFont GraphFont(int px, bool bold, double spacing) {
    QFont f(u"Segoe UI"_s);
    f.setPixelSize(px);
    f.setBold(bold);
    if (spacing != 0.0) f.setLetterSpacing(QFont::AbsoluteSpacing, spacing);
    return f;
}

int Advance(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 4) return Fail(reply, size, "cj_qt_advance(px, bold, spacing, text)");
    if (!QtUsable()) return Fail(reply, size, g_err.c_str());
    if (!CjQtAppReady(15000)) return Fail(reply, size, "cj_qt_advance: Qt's application did not come up");
    QFontMetrics fm(GraphFont(atoi(argv[0]), atoi(argv[1]) != 0, atof(argv[2])));
    snprintf(reply, size, "%d", fm.horizontalAdvance(QString::fromUtf8(argv[3])));
    return 1;
}

// cj_qt_font_height(px, bold) -> QFontMetrics(QFont("Segoe UI" ...)).height() (the quest graph's far-out names)
int FontHeight(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 2) return Fail(reply, size, "cj_qt_font_height(px, bold)");
    if (!QtUsable()) return Fail(reply, size, g_err.c_str());
    if (!CjQtAppReady(15000)) return Fail(reply, size, "cj_qt_font_height: Qt's application did not come up");
    QFontMetrics fm(GraphFont(atoi(argv[0]), atoi(argv[1]) != 0, 0.0));
    snprintf(reply, size, "%d", fm.height());
    return 1;
}

// cj_qt_elide(pt, mode, width, text) -> QFontMetrics(QFont("Segoe UI", pt)).elidedText(text, mode, width) (mode: Qt's
// TextElideMode - 0 left, 1 right, 2 middle; the quest graph's card measures its examples so)
int Elide(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 4) return Fail(reply, size, "cj_qt_elide(pt, mode, width, text)");
    if (!QtUsable()) return Fail(reply, size, g_err.c_str());
    if (!CjQtAppReady(15000)) return Fail(reply, size, "cj_qt_elide: Qt's application did not come up");
    QFontMetrics fm(QFont(u"Segoe UI"_s, atoi(argv[0])));
    QString t = fm.elidedText(QString::fromUtf8(argv[3]), static_cast<Qt::TextElideMode>(atoi(argv[1])), atoi(argv[2]));
    snprintf(reply, size, "%s", t.toUtf8().constData());
    return 1;
}

int Paint(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 4) return Fail(reply, size, "cj_qt_paint(out, w, h, commands)");
    if (!QtUsable()) return Fail(reply, size, g_err.c_str());
    if ((strstr(argv[3], "glyph") || strstr(argv[3], "text") || strstr(argv[3], "font")) && !CjQtAppReady(15000))
        return Fail(reply, size, "cj_qt_paint: Qt's application did not come up (text needs it)");
    int w = atoi(argv[1]), h = atoi(argv[2]);
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return Fail(reply, size, "cj_qt_paint: a size out of range");
    // device W H X Y (the first line): painted as into a window of W x H, the picture its part at X Y (a widget's
    // painter on its window's backing store: a dashed line's phase is worked out against that device's rect)
    int dev_x = 0, dev_y = 0, dev_w = w, dev_h = h;
    bool device = strncmp(argv[3], "device ", 7) == 0;
    if (device) {
        const QStringList d = QString::fromUtf8(argv[3]).section(QChar(0x0a), 0, 0).split(QLatin1Char(' '));
        dev_w = d.value(1).toInt(), dev_h = d.value(2).toInt(), dev_x = d.value(3).toInt(), dev_y = d.value(4).toInt();
        if (dev_w < w || dev_h < h || dev_w > 8192 || dev_h > 8192) device = false, dev_w = w, dev_h = h, dev_x = dev_y = 0;
    }
    QImage img(dev_w, dev_h, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::transparent);
    {
        QPainter p(&img);
        QTransform base;
        const QTransform redirect = QTransform::fromTranslate(dev_x, dev_y);
        auto world = [&](const QTransform& m) { p.setWorldTransform(m * redirect); };
        world(QTransform());
        const QStringList lines = QString::fromUtf8(argv[3]).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
        for (const QString& line : lines) {
            const QStringList a = line.split(QLatin1Char(' '), Qt::SkipEmptyParts);
            if (a.isEmpty()) continue;
            const QString& c = a[0];
            auto n = [&](int i) { return i < a.size() ? a[i].toDouble() : 0.0; };
            auto ni = [&](int i) { return i < a.size() ? a[i].toInt() : 0; };
            if (c == u"fill") {
                p.save();
                p.setCompositionMode(QPainter::CompositionMode_Source);
                p.fillRect(img.rect(), Colour(a.value(1)));
                p.restore();
            } else if (c == u"aa") {
                p.setRenderHint(QPainter::Antialiasing, ni(1) != 0);
            } else if (c == u"pen") {
                QPen pen(Colour(a.value(1)));
                pen.setWidthF(n(2));
                if (a.size() > 3) pen.setCapStyle(static_cast<Qt::PenCapStyle>(ni(3)));
                if (a.size() > 4) pen.setJoinStyle(static_cast<Qt::PenJoinStyle>(ni(4)));
                if (a.size() > 5) pen.setStyle(static_cast<Qt::PenStyle>(ni(5)));
                p.setPen(pen);
            } else if (c == u"nopen") {
                p.setPen(Qt::NoPen);
            } else if (c == u"brush") {
                p.setBrush(Colour(a.value(1)));
            } else if (c == u"nobrush") {
                p.setBrush(Qt::NoBrush);
            } else if (c == u"rect") {
                p.drawRect(QRect(ni(1), ni(2), ni(3), ni(4)));
            } else if (c == u"rectf") {
                p.drawRect(QRectF(n(1), n(2), n(3), n(4)));
            } else if (c == u"rrect") {
                p.drawRoundedRect(QRect(ni(1), ni(2), ni(3), ni(4)), n(5), n(6));
            } else if (c == u"rrectf") {
                p.drawRoundedRect(QRectF(n(1), n(2), n(3), n(4)), n(5), n(6));
            } else if (c == u"poly") {
                QPolygon poly;
                for (int i = 1; i + 1 < a.size(); i += 2) poly << QPoint(ni(i), ni(i + 1));
                p.drawPolygon(poly);
            } else if (c == u"polyf") {
                QPolygonF poly;
                for (int i = 1; i + 1 < a.size(); i += 2) poly << QPointF(n(i), n(i + 1));
                p.drawPolygon(poly);
            } else if (c == u"polylinef") {
                QPolygonF poly;
                for (int i = 1; i + 1 < a.size(); i += 2) poly << QPointF(n(i), n(i + 1));
                p.drawPolyline(poly);
            } else if (c == u"font") {
                // font <pointsize> <bold 0|1>: the painter's own font (the application's) at that point size
                QFont f = p.font();
                f.setPointSizeF(n(1));
                f.setBold(ni(2) != 0);
                p.setFont(f);
            } else if (c == u"glyph") {
                // glyph RRGGBBAA x y w h pixelsize codepoint(hex): a Windows icon font's sign as WinFontIconEngine
                // paints it (Segoe Fluent Icons, else Segoe MDL2 Assets, no font merging; centred in the box)
                QFont f(QStringList{u"Segoe Fluent Icons"_s, u"Segoe MDL2 Assets"_s});
                f.setStyleStrategy(QFont::NoFontMerging);
                f.setPixelSize(ni(6));
                p.save();
                p.setFont(f);
                p.setPen(Colour(a.value(1)));
                const QChar sign(a.value(7).toUShort(nullptr, 16));
                p.drawText(QRect(ni(2), ni(3), ni(4), ni(5)), Qt::AlignCenter, QString(sign));
                p.restore();
            } else if (c == u"text") {
                // text x y <the rest of the line>: drawText(QPointF, text) - the text's baseline at y
                QString t = line.section(QLatin1Char(' '), 3, -1, QString::SectionSkipEmpty);
                p.drawText(QPointF(n(1), n(2)), t);
            } else if (c == u"line") {
                p.drawLine(ni(1), ni(2), ni(3), ni(4));
            } else if (c == u"linef") {
                p.drawLine(QLineF(n(1), n(2), n(3), n(4)));
            } else if (c == u"ellipse") {
                p.drawEllipse(QRect(ni(1), ni(2), ni(3), ni(4)));
            } else if (c == u"ellipsef") {
                p.drawEllipse(QRectF(n(1), n(2), n(3), n(4)));
            } else if (c == u"image") {
                // (QPixmap(file): a raster pixmap holds its picture premultiplied, or RGB32 without transparency)
                QString file = line.section(QLatin1Char(' '), 5, -1, QString::SectionSkipEmpty);
                QImage pic(file);
                if (pic.isNull()) continue;
                pic = pic.convertToFormat(pic.hasAlphaChannel() ? QImage::Format_ARGB32_Premultiplied : QImage::Format_RGB32);
                if (ni(3) > 0 && ni(4) > 0)
                    pic = pic.scaled(ni(3), ni(4), Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
                p.drawImage(QPoint(ni(1), ni(2)), pic);
            } else if (c == u"imagefast" || c == u"imagesmooth") {
                // imagefast x y w h file: drawn into the box as QPainter::drawPixmap(rect, pixmap) does without
                // SmoothPixmapTransform (an icon engine's 32 px picture in a 24 px box)
                QString file = line.section(QLatin1Char(' '), 5, -1, QString::SectionSkipEmpty);
                QImage pic(file);
                if (pic.isNull()) continue;
                pic = pic.convertToFormat(pic.hasAlphaChannel() ? QImage::Format_ARGB32_Premultiplied
                                                                : QImage::Format_RGB32);
                p.save();
                p.setRenderHint(QPainter::SmoothPixmapTransform, c == u"imagesmooth");
                p.drawImage(QRect(ni(1), ni(2), ni(3), ni(4)), pic);
                p.restore();
            } else if (c == u"glyphpt") {
                // glyphpt RRGGBBAA x y w h pointsize codepoint: the sign at a point size (PE_IndicatorHeaderArrow)
                QFont f(QStringList{u"Segoe Fluent Icons"_s, u"Segoe MDL2 Assets"_s});
                f.setStyleStrategy(QFont::NoFontMerging);
                f.setPointSize(ni(6));
                p.save();
                p.setFont(f);
                p.setPen(Colour(a.value(1)));
                const QChar sign(a.value(7).toUShort(nullptr, 16));
                p.drawText(QRect(ni(2), ni(3), ni(4), ni(5)), Qt::AlignCenter, QString(sign));
                p.restore();
            } else if (c == u"device") {
                // (read before the painter: the first line)
            } else if (c == u"view") {
                base = QTransform(n(1), 0, 0, n(1), 0, 0) * QTransform::fromTranslate(-n(2), -n(3));
                world(base);
            } else if (c == u"item") {
                world(QTransform::fromTranslate(n(1), n(2)) * base);
            } else if (c == u"world") {
                world(base);
            } else if (c == u"path" || c == u"clippath") {
                QPainterPath path;
                for (int i = 1; i < a.size();) {
                    if (a[i] == u"M" && i + 2 < a.size()) {
                        path.moveTo(n(i + 1), n(i + 2));
                        i += 3;
                    } else if (a[i] == u"L" && i + 2 < a.size()) {
                        path.lineTo(n(i + 1), n(i + 2));
                        i += 3;
                    } else if (a[i] == u"Z") {
                        path.closeSubpath();
                        i += 1;
                    } else {
                        i += 1;
                    }
                }
                if (c == u"path") p.drawPath(path);
                else p.setClipPath(path);
            } else if (c == u"fillrectf") {
                p.fillRect(QRectF(n(1), n(2), n(3), n(4)), Colour(a.value(5)));
            } else if (c == u"dash") {
                QList<qreal> dashes;
                for (int i = 1; i < a.size(); ++i) dashes << n(i);
                QPen pen = p.pen();
                pen.setDashPattern(dashes);
                p.setPen(pen);
            } else if (c == u"gears") {
                // build_view.Spheres.paintEvent: the logo's two rings with their teeth, turned by `turn` (rad), in
                // a w x h box at x y - the left one with it, the right one against it (its teeth between)
                const double x0 = n(1), y0 = n(2), w = n(3), h = n(4), turn = n(5);
                const double R = 250, W = 64, TIP = 250 + 32 + 46, OFF = 130;
                const int TEETH = 12;
                const double k = std::min({h * 0.92 / (2 * TIP), w * 0.9 / (2 * (OFF + TIP)), 0.6});
                const double cx = x0 + w / 2, cy = y0 + h / 2;
                const double inner = (R - W / 2) * k, root = (R + W / 2) * k, tip = TIP * k;
                const double step = 2 * M_PI / TEETH;
                p.setPen(Qt::NoPen);
                p.setBrush(Colour(a.value(6)));
                const QPointF centres[2] = {QPointF(cx - OFF * k, cy), QPointF(cx + OFF * k, cy)};
                for (int g = 0; g < 2; ++g) {
                    const QPointF c0 = centres[g], other = centres[1 - g];
                    const double angle = g == 0 ? turn : -turn + step / 2;
                    QPainterPath path;
                    path.addEllipse(c0, root, root);
                    for (int i = 0; i < TEETH; ++i) {
                        const double ang = angle + i * step;
                        const double dx = c0.x() + tip * std::cos(ang) - other.x(), dy = c0.y() + tip * std::sin(ang) - other.y();
                        if (std::sqrt(dx * dx + dy * dy) < tip + 14 * k) continue;   // it would reach into the other
                        QPolygonF tooth;
                        const double fs[4] = {-0.32, -0.17, 0.17, 0.32};
                        const double rads[4] = {root - 4 * k, tip, tip, root - 4 * k};
                        for (int q = 0; q < 4; ++q)
                            tooth << QPointF(c0.x() + rads[q] * std::cos(ang + fs[q] * step),
                                             c0.y() + rads[q] * std::sin(ang + fs[q] * step));
                        QPainterPath tp;
                        tp.addPolygon(tooth);
                        path = path.united(tp);
                    }
                    QPainterPath hole;
                    hole.addEllipse(c0, inner, inner);
                    p.drawPath(path.subtracted(hole));
                }
            } else if (c == u"ellipsec") {
                p.drawEllipse(QPointF(n(1), n(2)), n(3), n(4));
            } else if (c == u"fontpx") {
                p.setFont(GraphFont(ni(1), ni(2) != 0, n(3)));
            } else if (c == u"textrect") {
                p.drawText(QRectF(n(1), n(2), n(3), n(4)), ni(5), Rest(line, 6));
            } else if (c == u"textelide") {
                // (the text up to a 0x1f elided, what follows it put after: a label and its mark)
                QString t = Rest(line, 7), tail;
                const int cut = t.indexOf(QChar(0x1f));
                if (cut >= 0) {
                    tail = t.mid(cut + 1);
                    t = t.left(cut);
                }
                t = QFontMetrics(p.font()).elidedText(t, Qt::ElideRight, ni(6)) + tail;
                p.drawText(QRectF(n(1), n(2), n(3), n(4)), ni(5), t);
            } else if (c == u"fontfam") {
                // fontfam <px> <bold 0|1> <family ...>: a font of its own (the style's Segoe Fluent Icons)
                QFont f(Rest(line, 3));
                f.setPixelSize(ni(1));
                f.setBold(ni(2) != 0);
                p.setFont(f);
            } else if (c == u"cliprect") {
                p.setClipRect(QRectF(n(1), n(2), n(3), n(4)));
            } else if (c == u"opacity") {
                // opacity <0..1>: what follows painted so (a QGraphicsItem's opacity, as the view paints it)
                p.setOpacity(n(1));
            } else if (c == u"save") {
                p.save();
            } else if (c == u"restore") {
                p.restore();
            }
        }
    }
    if (device) img = img.copy(dev_x, dev_y, w, h);
    QString out = QString::fromUtf8(argv[0]);
    const bool fast = argc > 4 && strcmp(argv[4], "fast") == 0;
    if (argc > 4 && !fast) {            // (a smaller copy: QPixmap.scaled(w, h, KeepAspectRatio, Smooth))
        const QStringList s = QString::fromUtf8(argv[4]).split(QLatin1Char(' '), Qt::SkipEmptyParts);
        if (s.size() == 2 && s[0].toInt() > 0 && s[1].toInt() > 0)
            img = img.scaled(s[0].toInt(), s[1].toInt(), Qt::KeepAspectRatio, Qt::SmoothTransformation);
        w = img.width();
        h = img.height();
    }
    if (!img.save(out + ".tmp.png", "PNG", fast ? 100 : -1))
        return Fail(reply, size, "cj_qt_paint: cannot write the picture");
    std::wstring tmp = Wide((std::string(argv[0]) + ".tmp.png").c_str()), dst = Wide(argv[0]);
    if (!MoveFileExW(tmp.c_str(), dst.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(tmp.c_str());
        return Fail(reply, size, "cj_qt_paint: cannot put the picture in place");
    }
    snprintf(reply, size, "%d\t%d", w, h);
    return 1;
}

// --- the file dialog's model (QFileSystemModel as QFileDialog sets it up), its rows as Qt words them
// QFileSystemModelSorter: the column's order, folders before files by name and size, ties by the name (natural,
// case aside)
bool Before(const QFileInfo& l, const QFileInfo& r, int column, const QCollator& nat, const QMimeDatabase& mime) {
    switch (column) {
    case 1:
        if (l.isDir() != r.isDir()) return l.isDir();
        if (l.size() != r.size()) return l.size() < r.size();
        return nat.compare(l.fileName(), r.fileName()) < 0;
    case 2: {
        auto type = [&](const QFileInfo& f) {
            if (f.isDir()) return QStringLiteral("File Folder");
            const QMimeType m = mime.mimeTypeForFile(f);
            return m.comment().isEmpty() ? m.name() : m.comment();
        };
        const int c = nat.compare(type(l), type(r));
        if (c == 0) return nat.compare(l.fileName(), r.fileName()) < 0;
        return c < 0;
    }
    case 3: {
        const QDateTime a = l.lastModified(QTimeZone::UTC), b = r.lastModified(QTimeZone::UTC);
        if (a == b) return nat.compare(l.fileName(), r.fileName()) < 0;
        return a < b;
    }
    default:
        if (l.isDir() != r.isDir()) return l.isDir();
        return nat.compare(l.fileName(), r.fileName()) < 0;
    }
}

// cj_qt_dir(folder, column, descending 0|1, name filters ("*.cjkey;*.w3q", "" all), dirs only 0|1, out)
//   out: a line per entry, "name \t dir 0|1 \t size \t date" (size: QLocale's formattedDataSize, "" for a folder;
//   date: the system locale's short format) -> the count. The model's filter: AllEntries | NoDotAndDotDot | AllDirs
//   (dirs only: AllDirs | NoDotAndDotDot); a name filter hides the files that do not match (nameFilterDisables off)
int Dir(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 6) return Fail(reply, size, "cj_qt_dir(folder, column, descending, filters, dirs only, out)");
    if (!QtUsable()) return Fail(reply, size, g_err.c_str());
    QDir dir(QString::fromUtf8(argv[0]));
    if (!dir.exists()) return Fail(reply, size, "cj_qt_dir: no such folder");
    const int column = atoi(argv[1]);
    const bool descending = atoi(argv[2]) != 0, dirs_only = atoi(argv[4]) != 0;
    QDir::Filters f = dirs_only ? (QDir::AllDirs | QDir::NoDotAndDotDot)
                                : (QDir::AllEntries | QDir::NoDotAndDotDot | QDir::AllDirs);
    QFileInfoList all = dir.entryInfoList(f, QDir::NoSort);
    const QStringList filters = QString::fromUtf8(argv[3]).split(QLatin1Char(';'), Qt::SkipEmptyParts);
    QList<QRegularExpression> res;
    for (const QString& p : filters)
        res << QRegularExpression(QRegularExpression::wildcardToRegularExpression(p),
                                  QRegularExpression::CaseInsensitiveOption);
    QFileInfoList rows;
    for (const QFileInfo& fi : all) {
        if (!fi.isDir() && !res.isEmpty()) {
            bool ok = false;
            for (const auto& re : res) if (re.match(fi.fileName()).hasMatch()) { ok = true; break; }
            if (!ok) continue;
        }
        rows << fi;
    }
    QCollator nat;
    nat.setNumericMode(true);
    nat.setCaseSensitivity(Qt::CaseInsensitive);
    QMimeDatabase mime;
    std::stable_sort(rows.begin(), rows.end(), [&](const QFileInfo& a, const QFileInfo& b) {
        return descending ? Before(b, a, column, nat, mime) : Before(a, b, column, nat, mime);
    });
    const QLocale loc = QLocale::system();
    QString text;
    for (const QFileInfo& fi : rows) {
        text += fi.fileName() + QLatin1Char('\t') + (fi.isDir() ? u"1"_s : u"0"_s) + QLatin1Char('\t') +
                (fi.isDir() ? QString() : loc.formattedDataSize(fi.size())) + QLatin1Char('\t') +
                loc.toString(fi.lastModified(QTimeZone::LocalTime), QLocale::ShortFormat) + QLatin1Char('\n');
    }
    QFile out(QString::fromUtf8(argv[5]));
    if (!out.open(QIODevice::WriteOnly) || out.write(text.toUtf8()) < 0)
        return Fail(reply, size, "cj_qt_dir: cannot write");
    snprintf(reply, size, "%d", static_cast<int>(rows.size()));
    return 1;
}

// cj_qt_rich(out.png, width, "html" | "markdown", source file, font px, RRGGBBAA text, RRGGBBAA background,
//            RRGGBBAA link) -> "w\th": a QTextBrowser's document as Qt sets and paints it - its default font Segoe UI at
//   that size (the widget's), the document's margin 4, set into the width (the viewport's), painted with the text
//   colour of the widget's palette onto its background (opaque: ClearType, as in the window)
//   [margin]: the document's margin (a QLabel's: 0), [anchor x y]: no picture - the link (href) at that point of the
//   document, "" when none (QAbstractTextDocumentLayout::anchorAt)
int Rich(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 8) return Fail(reply, size, "cj_qt_rich(out, width, html|markdown, file, px, text, bg, link)");
    if (!QtUsable()) return Fail(reply, size, g_err.c_str());
    if (!CjQtAppReady(15000)) return Fail(reply, size, "cj_qt_rich: Qt's application did not come up");
    QFile in(QString::fromUtf8(argv[3]));
    if (!in.open(QIODevice::ReadOnly)) return Fail(reply, size, "cj_qt_rich: cannot read the text");
    const QString text = QString::fromUtf8(in.readAll());
    const int width = atoi(argv[1]);
    if (width <= 0 || width > 8192) return Fail(reply, size, "cj_qt_rich: a width out of range");
    QTextDocument doc;
    // (the app sets the text before its sheet polishes the widget: the importer measures its margins with the
    // application's font, Segoe UI 9 pt - the markdown's paragraphs pointSize * 2 / 3 apart - then the sheet's px)
    doc.setDefaultFont(QFont(u"Segoe UI"_s, 9));
    if (QString::fromUtf8(argv[2]) == u"markdown") doc.setMarkdown(text);
    else doc.setHtml(text);
    QFont f(u"Segoe UI"_s);
    f.setPixelSize(atoi(argv[4]));
    doc.setDefaultFont(f);
    if (argc > 8 && argv[8][0]) {            // (a QLabel's: no margin, wrapped at words only - a long one sticks out)
        doc.setDocumentMargin(atof(argv[8]));
        QTextOption o = doc.defaultTextOption();
        o.setWrapMode(QTextOption::WordWrap);
        doc.setDefaultTextOption(o);
    }
    doc.setTextWidth(width);
    if (argc > 11 && strcmp(argv[9], "anchor") == 0) {
        const QString href = doc.documentLayout()->anchorAt(QPointF(atof(argv[10]), atof(argv[11])));
        snprintf(reply, size, "%s", href.toUtf8().constData());
        return 1;
    }
    const int h = qMax(1, qCeil(doc.size().height()));
    if (h > 32768) return Fail(reply, size, "cj_qt_rich: the text is too long to paint");
    QImage img(width, h, QImage::Format_ARGB32_Premultiplied);
    img.fill(Colour(QString::fromUtf8(argv[6])));
    {
        QPainter p(&img);
        QAbstractTextDocumentLayout::PaintContext ctx;
        ctx.palette.setColor(QPalette::Text, Colour(QString::fromUtf8(argv[5])));
        ctx.palette.setColor(QPalette::Link, Colour(QString::fromUtf8(argv[7])));
        doc.documentLayout()->draw(&p, ctx);
    }
    QString out = QString::fromUtf8(argv[0]);
    if (!img.save(out, "PNG")) return Fail(reply, size, "cj_qt_rich: cannot write the picture");
    snprintf(reply, size, "%d\t%d\t%d", width, h, qCeil(doc.idealWidth()));   // (the widest line or word)
    return 1;
}

// cj_qt_mime(file) -> the Type column's words (QAbstractFileIconProvider::type: the MIME type's comment, else its name)
int Mime(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_qt_mime(file)");
    if (!QtUsable()) return Fail(reply, size, g_err.c_str());
    const QFileInfo fi(QString::fromUtf8(argv[0]));
    QString t;
    if (fi.isDir()) t = QStringLiteral("File Folder");
    else {
        const QMimeType m = QMimeDatabase().mimeTypeForFile(fi);
        t = m.comment().isEmpty() ? m.name() : m.comment();
    }
    snprintf(reply, size, "%s", t.toUtf8().constData());
    return 1;
}
}  // namespace

TW3SE_EXPORT int TW3SE_PluginQuery(TW3SE_PluginInfo* info) {
    info->name = "cj_qt";
    info->author = "Conjunction";
    info->version = 0x00000100;
    info->minInterface = 16;
    return 1;
}

// for cj_qt_gl.cpp: Qt loaded (or why not) and its folder
bool CjQtLoad(std::string* err, std::wstring* dir) {
    if (!LoadQt()) {
        *err = g_err;
        return false;
    }
    *dir = g_qt_dir;
    return true;
}
int CjQtMeshLoad(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int CjQtMeshRender(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int CjQtMeshFree(int argc, const char* const* argv, char* reply, uint32_t size, void*);
void CjQtGlStop();
int CjQtGlStart(int argc, const char* const* argv, char* reply, uint32_t size, void*);
int CjQtMeshReady(int argc, const char* const* argv, char* reply, uint32_t size, void*);

// plugin reload: Qt's thread (the 3D view) ends before the DLL is freed
TW3SE_EXPORT int TW3SE_PluginUnload(void) {
    CjQtGlStop();
    return 0;
}

TW3SE_EXPORT int TW3SE_PluginLoad(const TW3SE_Interface* api) {
    g_api = api;
    api->RegisterLuaFunction("cj_qt_paint", &Paint, nullptr);
    api->RegisterLuaFunction("cj_qt_dir", &Dir, nullptr);
    api->RegisterLuaFunction("cj_qt_mime", &Mime, nullptr);
    api->RegisterLuaFunction("cj_qt_rich", &Rich, nullptr);
    api->RegisterLuaFunction("cj_qt_advance", &Advance, nullptr);
    api->RegisterLuaFunction("cj_qt_font_height", &FontHeight, nullptr);
    api->RegisterLuaFunction("cj_qt_elide", &Elide, nullptr);
    api->RegisterLuaFunction("cj_qt_mesh_load", &CjQtMeshLoad, nullptr);
    api->RegisterLuaFunction("cj_qt_mesh_render", &CjQtMeshRender, nullptr);
    api->RegisterLuaFunction("cj_qt_mesh_free", &CjQtMeshFree, nullptr);
    api->RegisterLuaFunction("cj_qt_gl_start", &CjQtGlStart, nullptr);
    api->RegisterLuaFunction("cj_qt_mesh_ready", &CjQtMeshReady, nullptr);
    api->Log("cj_qt", "loaded (Qt loads on the first picture)");
    return 1;
}

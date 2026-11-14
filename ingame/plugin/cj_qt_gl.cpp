// cj_qt's 3D preview (meshview.MeshView): the app's own OpenGL drawing - the same Qt, the same shaders, a 4-sample
// framebuffer with a 24-bit depth buffer as QOpenGLWidget has it - into a picture. Qt runs on a thread of its own
// (a QGuiApplication there, an offscreen surface and its context): the game's threads never touch OpenGL. A call
// posts its job to that thread and waits for it.
//
//   cj_qt_mesh_load(file) -> id        the parts as meshview.lua wrote them (see ReadParts)
//   cj_qt_mesh_load(file, "async") -> ticket    the same without waiting: cj_qt_mesh_ready(ticket) -> "busy" | id
//   cj_qt_mesh_render(id, w, h, yaw, pitch, dist, cx, cy, cz, radius, out.png) -> "w\th"
//   cj_qt_mesh_free(id)
//   cj_qt_gl_start() -> "ready" | "starting" | "!why"     Qt's thread started without waiting for it (its first
//                                                         start takes half a second: the game's frame goes on)
#include "tw3se/tw3se.h"

#include <windows.h>

#include <QtCore/QCoreApplication>
#include <QtGui/QGuiApplication>
#include <QtGui/QFont>
#include <QtGui/QFontMetrics>
#include <QtGui/QImage>
#include <QtGui/QPainter>
#include <QtGui/QMatrix4x4>
#include <QtGui/QOffscreenSurface>
#include <QtGui/QOpenGLContext>
#include <QtGui/QOpenGLFunctions>
#include <QtGui/QSurfaceFormat>
#include <QtGui/QVector3D>
#include <QtOpenGL/QOpenGLBuffer>
#include <QtOpenGL/QOpenGLFramebufferObject>
#include <QtOpenGL/QOpenGLShaderProgram>
#include <QtOpenGL/QOpenGLTexture>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

bool CjQtLoad(std::string* err, std::wstring* dir);   // cj_qt.cpp: Qt's DLLs, the folder they are in

namespace {

const char* VERTEX = R"(
attribute vec3 pos;
attribute vec2 uv;
attribute vec3 normal;
uniform mat4 mvp;
uniform mat4 model;
varying vec2 v_uv;
varying vec3 v_normal;
void main() {
    gl_Position = mvp * vec4(pos, 1.0);
    v_uv = uv;
    v_normal = normalize((model * vec4(normal, 0.0)).xyz);
}
)";
const char* FRAGMENT = R"(
uniform sampler2D tex;
uniform sampler2D mask;
uniform float textured;
uniform float cutout;
uniform float tinted;                                   // 0 no, 1 by the mask, 2 all of it by shift 1
uniform vec3 shift1;                                    // hue 0..1, saturation and luminance -1..1
uniform vec3 shift2;
varying vec2 v_uv;
varying vec3 v_normal;
vec3 hsl(vec3 c) {
    float hi = max(max(c.r, c.g), c.b), lo = min(min(c.r, c.g), c.b), l = (hi + lo) * 0.5, d = hi - lo;
    if (d < 1e-5) return vec3(0.0, 0.0, l);
    float s = l > 0.5 ? d / (2.0 - hi - lo) : d / (hi + lo);
    float h = hi == c.r ? (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0) : hi == c.g ? (c.b - c.r) / d + 2.0
                                                                                  : (c.r - c.g) / d + 4.0;
    return vec3(h / 6.0, s, l);
}
vec3 rgb(vec3 c) {
    vec3 k = clamp(abs(mod(c.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return c.z + c.y * (k - 0.5) * (1.0 - abs(2.0 * c.z - 1.0));
}
vec3 shifted(vec3 c, vec3 sh) {
    vec3 h = hsl(c);
    h.x = fract(h.x - sh.x);                        // the game turns the hue the other way
    h.y = clamp(h.y * (1.0 + sh.y), 0.0, 1.0);
    h.z = sh.z > 0.0 ? mix(h.z, 1.0, sh.z) : h.z * (1.0 + sh.z);
    return rgb(h);
}
void main() {
    vec4 t = textured > 0.5 ? texture2D(tex, v_uv) : vec4(0.62, 0.62, 0.64, 1.0);
    if (cutout > 0.5 && t.a < 0.45) discard;            // hair, leaves: the texture's alpha cuts them out
    if (tinted > 1.5) {
        t.rgb = shifted(t.rgb, shift1);
    } else if (tinted > 0.5) {                          // the template's colours where the tint mask says
        // the mask says where colour goes; the diffuse says which: red parts take shift 1, blue parts shift 2
        vec4 m = texture2D(mask, v_uv);
        vec3 c = t.rgb;
        float second = clamp((c.b - c.r) * 4.0 + 0.5, 0.0, 1.0);
        vec3 tinted_c = mix(shifted(c, shift1), shifted(c, shift2), second);
        t.rgb = mix(c, tinted_c, max(m.r, m.g));
    }
    vec3 base = pow(t.rgb, vec3(2.2));                  // the texture is sRGB: light in linear space
    vec3 n = normalize(v_normal);
    if (!gl_FrontFacing) n = -n;                        // both sides (cloth, leaves, open shapes)
    vec3 sun = normalize(vec3(0.45, -0.75, 0.55));
    float diff = max(dot(n, sun), 0.0);
    float sky = 0.5 + 0.5 * n.z;                        // light from above, darker from below
    vec3 ambient = mix(vec3(0.10, 0.09, 0.08), vec3(0.34, 0.37, 0.42), sky);
    vec3 to_eye = vec3(0.0, -1.0, 0.0);                 // the camera looks along +y
    vec3 half_v = normalize(sun + to_eye);
    float shine = pow(max(dot(n, half_v), 0.0), 32.0) * 0.12 * diff;
    vec3 color = base * (ambient + diff * vec3(1.05, 0.98, 0.9)) + vec3(shine);
    gl_FragColor = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
}
)";

const unsigned GL_CW_ = 0x0900, GL_DEPTH_TEST_ = 0x0B71, GL_TRIANGLES_ = 0x0004, GL_FLOAT_ = 0x1406;

struct Part {
    std::vector<float> rows;
    std::string texture, mask;      // picture files ("" none); mask "*": the whole material takes shift 1
    bool cutout = false, has_mask = false, has_shift = false;
    float shift[2][3] = {};
};
struct GlPart {
    std::unique_ptr<QOpenGLBuffer> vbo;
    std::unique_ptr<QOpenGLTexture> tex, mask;
    int n = 0;
    const Part* part = nullptr;
};
struct Mesh {
    std::vector<Part> parts;
    std::vector<GlPart> gl;
};

// the worker: Qt's thread
std::thread* g_thread = nullptr;                // (never destroyed: a joinable one would end the process at exit)
std::mutex g_mx;
std::condition_variable g_cv;
std::deque<std::function<void()>> g_jobs;
bool g_started = false, g_ready = false, g_stop = false;
std::string g_gl_err;
QOffscreenSurface* g_surface = nullptr;
QOpenGLContext* g_ctx = nullptr;
QOpenGLShaderProgram* g_program = nullptr;
// (left to the end of the process, never destroyed: by then Windows has ended Qt's thread, and a buffer or texture
// let go without its context current would bring the game down as it closes)
std::map<int, std::unique_ptr<Mesh>>& g_meshes = *new std::map<int, std::unique_ptr<Mesh>>();
int g_next = 1;
std::map<int, int>& g_tickets = *new std::map<int, int>();     // a load not waited for -> its mesh (0: still busy)
int g_ticket = 1;

void Worker(std::wstring dir) {
    // (the platform plugin: platforms\qwindows.dll beside Qt's DLLs; the lab's Qt keeps its plugins one up)
    QCoreApplication::addLibraryPath(QString::fromStdWString(dir));
    QCoreApplication::addLibraryPath(QString::fromStdWString(dir + L"..\\plugins"));
    static int argc = 1;
    static char name[] = "cj_qt";
    static char* argv[] = {name, nullptr};
    QGuiApplication app(argc, argv);
    QSurfaceFormat fmt;
    fmt.setDepthBufferSize(24);
    fmt.setSamples(4);
    QOffscreenSurface surface;
    surface.setFormat(fmt);
    surface.create();
    QOpenGLContext ctx;
    ctx.setFormat(fmt);
    bool ok = ctx.create() && ctx.makeCurrent(&surface);
    QOpenGLShaderProgram program;
    if (ok) {
        program.addShaderFromSourceCode(QOpenGLShader::Vertex, VERTEX);
        program.addShaderFromSourceCode(QOpenGLShader::Fragment, FRAGMENT);
        program.bindAttributeLocation("pos", 0);
        program.bindAttributeLocation("uv", 1);
        program.bindAttributeLocation("normal", 2);
        ok = program.link();
        if (!ok) g_gl_err = "cj_qt: the 3D shaders: " + program.log().toStdString();
    } else {
        g_gl_err = "cj_qt: no OpenGL context";
    }
    {
        std::lock_guard<std::mutex> lk(g_mx);
        g_surface = &surface;
        g_ctx = &ctx;
        g_program = &program;
        g_ready = ok;
    }
    g_cv.notify_all();
    // (the fonts read once now, on this thread: the game's thread finds them read when it first asks for text -
    // 25.10., the first picture with text of a session took up to 500 ms of a frame)
    {
        QImage im(16, 16, QImage::Format_ARGB32_Premultiplied);
        QPainter p(&im);
        for (bool bold : {false, true}) {
            QFont f(QStringLiteral("Segoe UI"));
            f.setPixelSize(12);
            f.setBold(bold);
            p.setFont(f);
            p.drawText(0, 12, QStringLiteral("Ag"));
            (void)QFontMetrics(f).horizontalAdvance(QStringLiteral("Ag"));
        }
    }
    if (!ok) return;
    while (!g_stop) {
        std::function<void()> job;
        {
            std::unique_lock<std::mutex> lk(g_mx);
            g_cv.wait_for(lk, std::chrono::milliseconds(50), [] { return !g_jobs.empty(); });
            if (!g_jobs.empty()) {
                job = std::move(g_jobs.front());
                g_jobs.pop_front();
            }
        }
        if (job) job();
        app.processEvents();
    }
    // (stopped - the plugin goes: everything of OpenGL let go here, with its context current)
    g_meshes.clear();
    program.removeAllShaders();
    ctx.doneCurrent();
}

// runs fn on Qt's thread and waits for it
bool OnQt(std::function<void()> fn, std::string* err) {
    std::wstring dir;
    if (!CjQtLoad(err, &dir)) return false;
    {
        std::unique_lock<std::mutex> lk(g_mx);
        if (!g_started) {
            g_started = true;
            g_thread = new std::thread(Worker, dir);
        }
        if (!g_cv.wait_for(lk, std::chrono::seconds(20), [] { return g_ready || !g_gl_err.empty(); })) {
            *err = "cj_qt: OpenGL did not start";
            return false;
        }
        if (!g_ready) {
            *err = g_gl_err;
            return false;
        }
    }
    bool done = false;
    std::mutex dm;
    std::condition_variable dcv;
    {
        std::lock_guard<std::mutex> lk(g_mx);
        g_jobs.push_back([&] {
            fn();
            std::lock_guard<std::mutex> l2(dm);
            done = true;
            dcv.notify_all();
        });
    }
    g_cv.notify_all();
    std::unique_lock<std::mutex> lk(dm);
    if (!dcv.wait_for(lk, std::chrono::seconds(30), [&] { return done; })) {
        *err = "cj_qt: the 3D job took too long";
        return false;               // (the job still runs later: it only touches what stays alive)
    }
    return true;
}

// posts fn to Qt's thread without waiting (Qt started as OnQt starts it)
bool OnQtAsync(std::function<void()> fn, std::string* err) {
    if (!OnQt([] {}, err)) return false;          // (started and ready; an empty job)
    {
        std::lock_guard<std::mutex> lk(g_mx);
        g_jobs.push_back(std::move(fn));
    }
    g_cv.notify_all();
    return true;
}

// the file meshview.lua writes: "CJM1", the count of parts u32, then per part: the count of floats u32, cut-out u8,
// has mask u8, has shift u8, shift 6 x f32, the texture's file (u16 length, UTF-8), the mask's file (the same; "*" the
// whole material), the floats (f32)
bool ReadParts(const std::string& path, std::vector<Part>& out, std::string* err) {
    // (read without Qt: nothing of Qt may run before CjQtLoad has loaded Qt's own DLLs - the delay-load helper
    // would take the first Qt6Core.dll on the search path, maybe another version)
    int wn = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
    std::wstring wpath(wn > 0 ? wn - 1 : 0, L'\0');
    if (wn > 1) MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, &wpath[0], wn);
    FILE* fp = _wfopen(wpath.c_str(), L"rb");
    if (!fp) {
        *err = "cj_qt_mesh_load: cannot open " + path;
        return false;
    }
    std::vector<char> b;
    char chunk[65536];
    size_t got;
    while ((got = fread(chunk, 1, sizeof chunk, fp)) > 0) b.insert(b.end(), chunk, chunk + got);
    fclose(fp);
    const char* p = b.data();
    size_t n = b.size(), at = 0;
    auto need = [&](size_t k) { return at + k <= n; };
    auto u32 = [&]() { uint32_t v; memcpy(&v, p + at, 4); at += 4; return v; };
    auto u16 = [&]() { uint16_t v; memcpy(&v, p + at, 2); at += 2; return v; };
    auto f32 = [&]() { float v; memcpy(&v, p + at, 4); at += 4; return v; };
    if (!need(8) || memcmp(p, "CJM1", 4) != 0) {
        *err = "cj_qt_mesh_load: not a mesh file";
        return false;
    }
    at = 4;
    uint32_t count = u32();
    for (uint32_t k = 0; k < count; ++k) {
        Part part;
        if (!need(4 + 3 + 24 + 2)) { *err = "cj_qt_mesh_load: cut short"; return false; }
        uint32_t nf = u32();
        part.cutout = p[at++] != 0;
        part.has_mask = p[at++] != 0;
        part.has_shift = p[at++] != 0;
        for (int s = 0; s < 2; ++s) for (int c = 0; c < 3; ++c) part.shift[s][c] = f32();
        for (std::string* s : {&part.texture, &part.mask}) {
            if (!need(2)) { *err = "cj_qt_mesh_load: cut short"; return false; }
            uint16_t len = u16();
            if (!need(len)) { *err = "cj_qt_mesh_load: cut short"; return false; }
            s->assign(p + at, len);
            at += len;
        }
        if (!need(static_cast<size_t>(nf) * 4)) { *err = "cj_qt_mesh_load: cut short"; return false; }
        part.rows.resize(nf);
        memcpy(part.rows.data(), p + at, static_cast<size_t>(nf) * 4);
        at += static_cast<size_t>(nf) * 4;
        out.push_back(std::move(part));
    }
    return true;
}

// MeshView._texture: QOpenGLTexture(img) with LinearMipMapLinear, Linear, Repeat
std::unique_ptr<QOpenGLTexture> Texture(const std::string& file) {
    if (file.empty()) return nullptr;
    QImage img(QString::fromUtf8(file.c_str()));
    if (img.isNull()) return nullptr;
    auto tex = std::make_unique<QOpenGLTexture>(img);
    tex->setMinificationFilter(QOpenGLTexture::LinearMipMapLinear);
    tex->setMagnificationFilter(QOpenGLTexture::Linear);
    tex->setWrapMode(QOpenGLTexture::Repeat);
    return tex;
}

// MeshView._upload
void Upload(Mesh& m) {
    for (const Part& p : m.parts) {
        if (p.rows.empty()) continue;
        GlPart g;
        g.vbo = std::make_unique<QOpenGLBuffer>();
        g.vbo->create();
        g.vbo->bind();
        g.vbo->allocate(p.rows.data(), static_cast<int>(p.rows.size() * 4));
        g.vbo->release();
        g.tex = Texture(p.texture);
        g.mask = (p.has_mask && p.mask != "*") ? Texture(p.mask) : nullptr;
        g.n = static_cast<int>(p.rows.size() / 8);
        g.part = &p;
        m.gl.push_back(std::move(g));
    }
}

// MeshView.paintGL into a 4-sample framebuffer, resolved, read back
QImage Render(Mesh& m, int w, int h, double yaw, double pitch, double dist, const double c[3], double radius) {
    QOpenGLFramebufferObjectFormat ff;
    ff.setAttachment(QOpenGLFramebufferObject::CombinedDepthStencil);
    ff.setSamples(4);
    QOpenGLFramebufferObject fbo(w, h, ff);
    QOpenGLFramebufferObject resolved(w, h);
    fbo.bind();
    QOpenGLFunctions* f = g_ctx->functions();
    f->glViewport(0, 0, w, h);
    f->glClearColor(0.19f, 0.2f, 0.22f, 1.0f);
    f->glClear(0x4000 | 0x0100);
    f->glEnable(GL_DEPTH_TEST_);
    f->glFrontFace(GL_CW_);
    if (!m.gl.empty()) {
        QMatrix4x4 model;
        model.rotate(static_cast<float>(pitch), 1, 0, 0);
        model.rotate(static_cast<float>(-yaw), 0, 0, 1);
        model.translate(static_cast<float>(-c[0]), static_cast<float>(-c[1]), static_cast<float>(-c[2]));
        QMatrix4x4 view;
        view.lookAt(QVector3D(0, static_cast<float>(-dist), 0), QVector3D(0, 0, 0), QVector3D(0, 0, 1));
        QMatrix4x4 proj;
        proj.perspective(40.0f, static_cast<float>(static_cast<double>((std::max)(1, w)) / (std::max)(1, h)),
                         static_cast<float>(radius * 0.02), static_cast<float>(radius * 50));
        QOpenGLShaderProgram& prog = *g_program;
        prog.bind();
        prog.setUniformValue("mvp", proj * view * model);
        prog.setUniformValue("model", model);
        prog.setUniformValue("tex", 0);
        prog.setUniformValue("mask", 1);
        for (GlPart& g : m.gl) {
            const Part& part = *g.part;
            g.vbo->bind();
            prog.setUniformValue("cutout", (part.cutout && g.tex) ? 1.0f : 0.0f);
            float tinted = 0.0f;
            bool mask_whole = part.has_mask && part.mask == "*";
            if (g.tex && part.has_shift && (g.mask || mask_whole)) {
                tinted = g.mask ? 1.0f : 2.0f;
                for (int k = 0; k < 2; ++k) {
                    prog.setUniformValue(k == 0 ? "shift1" : "shift2",
                                         QVector3D(static_cast<float>(part.shift[k][0] / 360.0),
                                                   static_cast<float>(part.shift[k][1] / 100.0),
                                                   static_cast<float>(part.shift[k][2] / 100.0)));
                }
                if (g.mask) g.mask->bind(1);
            }
            prog.setUniformValue("tinted", tinted);
            prog.enableAttributeArray(0);
            prog.enableAttributeArray(1);
            prog.enableAttributeArray(2);
            prog.setAttributeBuffer(0, GL_FLOAT_, 0, 3, 32);
            prog.setAttributeBuffer(1, GL_FLOAT_, 12, 2, 32);
            prog.setAttributeBuffer(2, GL_FLOAT_, 20, 3, 32);
            if (g.tex) g.tex->bind(0);
            prog.setUniformValue("textured", g.tex ? 1.0f : 0.0f);
            f->glDrawArrays(GL_TRIANGLES_, 0, g.n);
            if (g.mask && tinted != 0.0f) g.mask->release(1);
            if (g.tex) g.tex->release();
            g.vbo->release();
        }
        prog.release();
    }
    fbo.release();
    QOpenGLFramebufferObject::blitFramebuffer(&resolved, &fbo);
    return resolved.toImage();
}

}  // namespace

int CjQtGlStart(int, const char* const*, char* reply, uint32_t size, void*) {
    std::string err;
    std::wstring dir;
    if (!CjQtLoad(&err, &dir)) {
        snprintf(reply, size, "!%s", err.c_str());
        return 1;
    }
    std::lock_guard<std::mutex> lk(g_mx);
    if (!g_started) {
        g_started = true;
        g_thread = new std::thread(Worker, dir);
    }
    snprintf(reply, size, "%s", g_ready ? "ready" : (!g_gl_err.empty() ? ("!" + g_gl_err).c_str() : "starting"));
    return 1;
}

// Qt's application on its way up (asked for, not there yet): nothing else of Qt may run meanwhile (cj_qt.cpp waits)
bool CjQtAppStarting() {
    std::lock_guard<std::mutex> lk(g_mx);
    return g_started && !g_ready && g_gl_err.empty();
}

// for cj_qt_paint's text (cj_qt.cpp): Qt's application up on its thread (started if it is not), waited for at
// most ms -> it is up
bool CjQtAppReady(int ms) {
    std::string err;
    std::wstring dir;
    if (!CjQtLoad(&err, &dir)) return false;
    {
        std::lock_guard<std::mutex> lk(g_mx);
        if (!g_started) {
            g_started = true;
            g_thread = new std::thread(Worker, dir);
        }
    }
    for (int waited = 0; waited < ms; waited += 5) {
        {
            std::lock_guard<std::mutex> lk(g_mx);
            if (g_ready) return true;
            if (!g_gl_err.empty()) return false;
        }
        Sleep(5);
    }
    return false;
}

// TW3SE_PluginUnload (cj_qt.cpp): Qt's thread ends, before the DLL goes
void CjQtGlStop() {
    {
        std::lock_guard<std::mutex> lk(g_mx);
        if (!g_thread) return;
        g_stop = true;
    }
    g_cv.notify_all();
    if (g_thread->joinable()) g_thread->join();
    delete g_thread;
    g_thread = nullptr;
    std::lock_guard<std::mutex> lk(g_mx);
    g_started = g_ready = g_stop = false;
    g_gl_err.clear();
    g_jobs.clear();
}

namespace {
int Fail(char* reply, uint32_t size, const std::string& s) {
    snprintf(reply, size, "%s", s.c_str());
    return 0;
}

}  // namespace

int CjQtMeshLoad(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 1) return Fail(reply, size, "cj_qt_mesh_load(file)");
    std::string err;
    std::wstring dir;
    if (!CjQtLoad(&err, &dir)) return Fail(reply, size, err);     // (Qt's own DLLs first: see ReadParts)
    auto mesh = std::make_unique<Mesh>();
    if (!ReadParts(argv[0], mesh->parts, &err)) return Fail(reply, size, err);
    if (argc >= 2 && !strcmp(argv[1], "async")) {
        // (posted, not waited for: the job owns the mesh; its answer goes under the ticket)
        int ticket;
        {
            std::lock_guard<std::mutex> lk(g_mx);
            ticket = g_ticket++;
            g_tickets[ticket] = 0;
        }
        std::shared_ptr<Mesh> owned(mesh.release());
        if (!OnQtAsync([owned, ticket]() mutable {
                Upload(*owned);
                int id = g_next++;
                g_meshes[id] = std::unique_ptr<Mesh>(new Mesh(std::move(*owned)));
                std::lock_guard<std::mutex> lk(g_mx);
                g_tickets[ticket] = id;
            }, &err))
            return Fail(reply, size, err);
        snprintf(reply, size, "%d", ticket);
        return 1;
    }
    int id = 0;
    Mesh* raw = mesh.get();
    if (!OnQt([&] {
            Upload(*raw);
            id = g_next++;
            g_meshes[id] = std::move(mesh);
        }, &err))
        return Fail(reply, size, err);
    snprintf(reply, size, "%d", id);
    return 1;
}

int CjQtMeshReady(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    int ticket = argc >= 1 ? atoi(argv[0]) : 0;
    std::lock_guard<std::mutex> lk(g_mx);
    auto it = g_tickets.find(ticket);
    if (it == g_tickets.end()) return Fail(reply, size, "cj_qt_mesh_ready: no such load");
    if (it->second == 0) {
        snprintf(reply, size, "busy");
        return 1;
    }
    snprintf(reply, size, "%d", it->second);
    g_tickets.erase(it);
    return 1;
}

int CjQtMeshRender(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    if (argc < 11) return Fail(reply, size, "cj_qt_mesh_render(id, w, h, yaw, pitch, dist, cx, cy, cz, radius, out)");
    int id = atoi(argv[0]), w = atoi(argv[1]), h = atoi(argv[2]);
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return Fail(reply, size, "cj_qt_mesh_render: a size out of range");
    double yaw = strtod(argv[3], nullptr), pitch = strtod(argv[4], nullptr), dist = strtod(argv[5], nullptr);
    double c[3] = {strtod(argv[6], nullptr), strtod(argv[7], nullptr), strtod(argv[8], nullptr)};
    double radius = strtod(argv[9], nullptr);
    std::string out = argv[10], err;
    bool wrote = false, found = false;
    if (!OnQt([&] {
            auto it = g_meshes.find(id);
            if (it == g_meshes.end()) return;
            found = true;
            QImage img = Render(*it->second, w, h, yaw, pitch, dist, c, radius);
            wrote = img.save(QString::fromUtf8(out.c_str()), "PNG", 100);   // (100: no compression - quick)
        }, &err))
        return Fail(reply, size, err);
    if (!found) return Fail(reply, size, "cj_qt_mesh_render: no mesh " + std::to_string(id));
    if (!wrote) return Fail(reply, size, "cj_qt_mesh_render: cannot write " + out);
    snprintf(reply, size, "%d\t%d", w, h);
    return 1;
}

int CjQtMeshFree(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    int id = argc >= 1 ? atoi(argv[0]) : 0;
    std::string err;
    std::wstring dir;
    if (CjQtLoad(&err, &dir)) OnQt([&] { g_meshes.erase(id); }, &err);
    reply[0] = 0;
    return 1;
}

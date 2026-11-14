// The game keeps running while another window is in front (MaximdeWinter 03.11.: "das Spiel darf nicht pausieren, wenn ich
// raustabbe"). DoNotPauseWhileStopped in the settings does not stop it: the game pauses when Windows tells its window
// it is no longer in front. As w3bg.dll does for the background game, but for the game one plays:
// - the window does not hear that it went to the back (WM_ACTIVATEAPP, WM_ACTIVATE, WM_KILLFOCUS, WM_NCACTIVATE), and
//   the game's own code asking for the front window is told its own (GetForegroundWindow / GetActiveWindow /
//   GetFocus called from witcher3.exe) - everything else (TW3SE, Windows, input) sees the real one;
// - while another window really is in front the game neither locks the mouse into its window (ClipCursor) nor moves
//   it (SetCursorPos): the mouse stays the user's. Keys and clicks go where Windows sends them, as before.
//
// On by itself once the game's window is there (MaximdeWinter 03.11.: "alles super" - mouse and keys stayed his); not in the
// background game, whose w3bg.dll does this already. Only while the window is in front (switched on from the back the
// game once stayed paused, 03.11.).
//
//   cj_keep_running("on" | "off" | "") -> "on <window>" | "off" | "no window"
//   cj_keep_running("diag") -> the front window as the original, the hook and Windows see it
#include "keeprun.h"

#include "tw3se/tw3se.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <intrin.h>
#include <psapi.h>
#include <stdio.h>
#include <string.h>

#pragma intrinsic(_ReturnAddress)

namespace keeprun {
namespace {

const TW3SE_Interface* g_api = nullptr;
HWND g_hwnd = nullptr;
WNDPROC g_proc = nullptr;               // the window's procedure before ours
volatile bool g_on = false;
bool g_hooked = false;
bool g_auto = true;                     // (until it is on, or turned off by hand; it goes on only while the game
                                        // window really is in front - 03.11.: switched on from the back,
                                        // the game once did not wake, and TW3SE's keys failed at 18:19)
float g_wait = 0.0f;
uintptr_t g_exe_lo = 0, g_exe_hi = 0;

typedef HWND(WINAPI* HwndFn)(void);
typedef BOOL(WINAPI* ClipFn)(const RECT*);
typedef BOOL(WINAPI* PosFn)(int, int);
HwndFn oGetForegroundWindow = nullptr, oGetActiveWindow = nullptr, oGetFocus = nullptr;
ClipFn oClipCursor = nullptr;
PosFn oSetCursorPos = nullptr;

bool FromGame(void* ret) {
    uintptr_t r = (uintptr_t)ret;
    return r >= g_exe_lo && r < g_exe_hi;
}

bool ReallyInFront() {
    HWND f = oGetForegroundWindow ? oGetForegroundWindow() : GetForegroundWindow();
    return f == g_hwnd;
}

HWND WINAPI hGetForegroundWindow(void) {
    if (g_on && FromGame(_ReturnAddress())) return g_hwnd;
    return oGetForegroundWindow();
}
HWND WINAPI hGetActiveWindow(void) {
    if (g_on && FromGame(_ReturnAddress())) return g_hwnd;
    return oGetActiveWindow();
}
HWND WINAPI hGetFocus(void) {
    if (g_on && FromGame(_ReturnAddress())) return g_hwnd;
    return oGetFocus();
}
BOOL WINAPI hClipCursor(const RECT* r) {
    if (g_on && r && !ReallyInFront()) return oClipCursor(nullptr);     // (no lock while the user works elsewhere)
    return oClipCursor(r);
}
BOOL WINAPI hSetCursorPos(int x, int y) {
    if (g_on && !ReallyInFront()) return TRUE;
    return oSetCursorPos(x, y);
}

LRESULT CALLBACK Proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (g_on) {
        switch (m) {
        case WM_ACTIVATEAPP:
            if (!w) return 0;
            break;
        case WM_ACTIVATE:
            if (LOWORD(w) == WA_INACTIVE) return 0;
            break;
        case WM_KILLFOCUS:
            return 0;
        case WM_NCACTIVATE:
            if (!w) return DefWindowProcW(h, m, w, l);       // (the title bar may show it is in the back)
            break;
        }
    }
    return CallWindowProcW(g_proc, h, m, w, l);
}

BOOL CALLBACK Biggest(HWND h, LPARAM out) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(h) || GetWindow(h, GW_OWNER)) return TRUE;
    RECT r;
    GetWindowRect(h, &r);
    long area = (r.right - r.left) * (r.bottom - r.top);
    HWND* best = (HWND*)out;
    if (!*best) { *best = h; return TRUE; }
    RECT b;
    GetWindowRect(*best, &b);
    if (area > (b.right - b.left) * (b.bottom - b.top)) *best = h;
    return TRUE;
}

void Hook(const char* name, void* detour, void** original) {
    void* target = (void*)GetProcAddress(GetModuleHandleW(L"user32.dll"), name);
    if (!target || !g_api->Hook(target, detour, original)) g_api->Log("cj_core", "keep running: no hook on %s", name);
}

bool On() {
    if (g_on) return true;
    if (!g_hwnd) {
        HWND best = nullptr;
        EnumWindows(&Biggest, (LPARAM)&best);
        g_hwnd = best;
    }
    if (!g_hwnd) return false;
    if (!g_hooked) {
        MODULEINFO mi = {};
        GetModuleInformation(GetCurrentProcess(), GetModuleHandleW(nullptr), &mi, sizeof(mi));
        g_exe_lo = (uintptr_t)mi.lpBaseOfDll;
        g_exe_hi = g_exe_lo + mi.SizeOfImage;
        Hook("GetForegroundWindow", (void*)&hGetForegroundWindow, (void**)&oGetForegroundWindow);
        Hook("GetActiveWindow", (void*)&hGetActiveWindow, (void**)&oGetActiveWindow);
        Hook("GetFocus", (void*)&hGetFocus, (void**)&oGetFocus);
        Hook("ClipCursor", (void*)&hClipCursor, (void**)&oClipCursor);
        Hook("SetCursorPos", (void*)&hSetCursorPos, (void**)&oSetCursorPos);
        g_hooked = true;
    }
    g_proc = (WNDPROC)SetWindowLongPtrW(g_hwnd, GWLP_WNDPROC, (LONG_PTR)&Proc);
    if (!g_proc) return false;
    g_on = true;
    if (!ReallyInFront()) {
        // already in the back (paused): it is told it is in front again
        if (oClipCursor) oClipCursor(nullptr);
        PostMessageW(g_hwnd, WM_ACTIVATEAPP, TRUE, 0);
        PostMessageW(g_hwnd, WM_NCACTIVATE, TRUE, 0);
        PostMessageW(g_hwnd, WM_ACTIVATE, WA_ACTIVE, 0);
        PostMessageW(g_hwnd, WM_SETFOCUS, 0, 0);
    }
    g_api->Log("cj_core", "keep running: on (window %p)", (void*)g_hwnd);
    return true;
}

void Off() {
    if (!g_on) return;
    g_on = false;
    if ((WNDPROC)GetWindowLongPtrW(g_hwnd, GWLP_WNDPROC) == &Proc) {
        SetWindowLongPtrW(g_hwnd, GWLP_WNDPROC, (LONG_PTR)g_proc);
    } else {
        g_api->Log("cj_core", "keep running: another procedure came after ours - it stays in the chain, passing on");
    }
    if (!ReallyInFront()) PostMessageW(g_hwnd, WM_ACTIVATEAPP, FALSE, 0);     // (as it really is)
    g_api->Log("cj_core", "keep running: off");
}

void Tick(float dt, void*) {
    if (!g_auto) return;
    g_wait -= dt;
    if (g_wait > 0.0f) return;
    g_wait = 1.0f;
    if (GetModuleHandleW(L"w3bg.dll")) { g_auto = false; return; }
    HWND best = nullptr;                    // (looked for anew each time: the game's small loading window comes first,
    EnumWindows(&Biggest, (LPARAM)&best);   // its real one seconds later)
    if (!best || GetForegroundWindow() != best) return;         // (only from the front: no messages to wake it)
    g_hwnd = best;
    if (On()) g_auto = false;
}

}  // namespace

void Init(const TW3SE_Interface* api) {
    g_api = api;
    api->RegisterOnTick(&Tick, nullptr);
}

int KeepRunning(int argc, const char* const* argv, char* reply, uint32_t size, void*) {
    const char* what = argc > 0 ? argv[0] : "";
    if (!strcmp(what, "on")) {
        if (!On()) { snprintf(reply, size, "no window"); return 1; }
    } else if (!strcmp(what, "off")) {
        g_auto = false;
        Off();
    } else if (!strcmp(what, "diag")) {
        // the front window three ways: the original (trampoline), through the hook (from this DLL: passed on), and
        // Windows' foreground thread past every hook
        GUITHREADINFO gti = {sizeof(gti)};
        GetGUIThreadInfo(0, &gti);
        HWND o = oGetForegroundWindow ? oGetForegroundWindow() : nullptr;
        snprintf(reply, size, "%s window %p | original %p | hooked %p | windows %p | exe %p-%p",
                 g_on ? "on" : "off", (void*)g_hwnd, (void*)o, (void*)GetForegroundWindow(), (void*)gti.hwndActive,
                 (void*)g_exe_lo, (void*)g_exe_hi);
        return 1;
    }
    if (g_on) snprintf(reply, size, "on %p", (void*)g_hwnd);
    else snprintf(reply, size, "off");
    return 1;
}

void Unload() { Off(); }

}  // namespace keeprun

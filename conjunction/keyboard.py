"""Typing into the editor's panel while the game keeps the focus.

The game pauses whenever its window is not the active one (an engine pause without a script-visible reason - checked
against every string of the exe), so the panel never takes the focus (WS_EX_NOACTIVATE). While the user types in
one of its fields, a low-level keyboard hook takes the keys away from the game and hands them to that field as Qt key
events. A click into the game or Esc ends typing.

The panel's window is never the active one, so Qt sends its fields no focus events of their own: no caret showed
until the first key and it never blinked, and a field's selection stayed when it was left (Maxim, 30.09.). Typing
sends them itself - FocusIn when a field is clicked, FocusOut when it is left (at the mouse button's release: what
the field does when it is left may rebuild the card, and the button clicked must still be there to take its click).
"""
import ctypes
import ctypes.wintypes as wt
import threading

from PySide6 import QtCore, QtGui, QtWidgets

user32 = ctypes.windll.user32
_GetForegroundWindow = ctypes.WINFUNCTYPE(ctypes.c_void_p)(("GetForegroundWindow", user32))
_GetKeyboardLayout =ctypes.WINFUNCTYPE(ctypes.c_void_p, wt.DWORD)(("GetKeyboardLayout", user32))
_ToUnicodeEx = ctypes.WINFUNCTYPE(ctypes.c_int, wt.UINT, wt.UINT, ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int,
                                  wt.UINT, ctypes.c_void_p)(("ToUnicodeEx", user32))
WH_KEYBOARD_LL, WM_KEYDOWN, WM_SYSKEYDOWN, LLKHF_INJECTED, LLKHF_EXTENDED = 13, 0x100, 0x104, 0x10, 0x01
VK_SHIFT, VK_CONTROL, VK_MENU, VK_CAPITAL, VK_ESCAPE = 0x10, 0x11, 0x12, 0x14, 0x1B
SIDES = {0xA0: VK_SHIFT, 0xA1: VK_SHIFT, 0xA2: VK_CONTROL, 0xA3: VK_CONTROL, 0xA4: VK_MENU, 0xA5: VK_MENU}
Q = QtCore.Qt
SPECIAL = {0x08: Q.Key_Backspace, 0x09: Q.Key_Tab, 0x0D: Q.Key_Return, 0x2E: Q.Key_Delete, 0x25: Q.Key_Left,
           0x26: Q.Key_Up, 0x27: Q.Key_Right, 0x28: Q.Key_Down, 0x24: Q.Key_Home, 0x23: Q.Key_End,
           0x21: Q.Key_PageUp, 0x22: Q.Key_PageDown, 0x2D: Q.Key_Insert, VK_SHIFT: Q.Key_Shift,
           VK_CONTROL: Q.Key_Control, VK_MENU: Q.Key_Alt, 0x20: Q.Key_Space}
# typing starts only with a click into a text field (lists, buttons, tabs never take the keys)
TEXT_WIDGETS = (QtWidgets.QLineEdit, QtWidgets.QAbstractSpinBox, QtWidgets.QPlainTextEdit, QtWidgets.QTextEdit)
PASS = {0x12, 0xA4, 0xA5, 0x5B, 0x5C, 0x5D}      # Alt (both), Windows (both), the menu key
# the keys Conjunction sends itself (agent.py, for the game) carry this in dwExtraInfo. Only those are left alone: every
# key of a remote session (Moonlight/Sunshine) is injected too, and typing must take them (Maxim 04.10.: no field
# took a key)
OWN_KEYS = 0x57335331


class KBDLL(ctypes.Structure):
    _fields_ = [("vkCode", wt.DWORD), ("scanCode", wt.DWORD), ("flags", wt.DWORD), ("time", wt.DWORD),
                ("extra", ctypes.c_void_p)]


def trace(what):
    """A line in Conjunction's log about typing (Maxim 30.09.: 'the caret is often not there', 'what I typed was gone' -
    what happened to the field is to be seen there)."""
    import time
    print(f"[typing {time.strftime('%H:%M:%S')}.{int(time.time() * 1000) % 1000:03d}] {what}", flush=True)


def name(widget):
    """A field in words: what it shows, or what it asks for."""
    import shiboken6
    if widget is None:
        return "-"
    if not shiboken6.isValid(widget):
        return "(gone)"
    text = widget.text() if hasattr(widget, "text") and callable(widget.text) else ""
    hint = widget.placeholderText() if hasattr(widget, "placeholderText") else ""
    return f"{type(widget).__name__} {(text or hint or widget.objectName())[:40]!r}"


SENDING = [False]                       # a focus event of ours on its way (not Qt's own)


def _focus(widget, kind):
    """A focus event sent to a field by hand (the window is never active: Qt sends none)."""
    import shiboken6
    if widget is not None and shiboken6.isValid(widget):
        SENDING[0] = True
        try:
            QtWidgets.QApplication.sendEvent(widget, QtGui.QFocusEvent(kind, QtCore.Qt.MouseFocusReason))
        finally:
            SENDING[0] = False


class KeyRouter(QtCore.QObject):
    key = QtCore.Signal(int, int, bool, int)    # vk, scan code, down, flags (from the hook thread)
    changed = QtCore.Signal(bool)               # typing on / off
    elsewhere = QtCore.Signal()                 # a key while typing, but another window is in front

    def __init__(self):
        super().__init__()
        self.target = None
        self.leaving = None                     # the field left with a mouse press: its FocusOut at the release
        self.active = False
        self.owner = None                       # () -> hwnd of the game window; keys are taken only while it is active
        self.state = (ctypes.c_ubyte * 256)()  # our own keyboard state: swallowed keys never reach Windows' one
        self.key.connect(self._deliver, QtCore.Qt.QueuedConnection)
        self.elsewhere.connect(self._elsewhere, QtCore.Qt.QueuedConnection)
        self._elsewhere_said = 0.0
        threading.Thread(target=self._run, daemon=True).start()

    # --- the hook thread
    def _run(self):
        proto = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_int, wt.WPARAM, wt.LPARAM)

        def cb(code, wparam, lparam):
            # only while the game is the active window: typing anywhere else on the PC is never ours
            if code >= 0 and self.active and self.owner and wparam in (WM_KEYDOWN, WM_SYSKEYDOWN) and \
                    _GetForegroundWindow() != self.owner():
                self.elsewhere.emit()           # (said in the log: a key while typing, the game not in front)
            if code >= 0 and self.active and self.owner and _GetForegroundWindow() == self.owner():
                k = ctypes.cast(lparam, ctypes.POINTER(KBDLL)).contents
                # Alt, Alt+Tab, the Windows keys stay Windows' (switching programs must always work)
                system = k.vkCode in PASS or user32.GetAsyncKeyState(VK_MENU) & 0x8000
                ours = k.flags & LLKHF_INJECTED and (k.extra or 0) == OWN_KEYS
                if not ours and not system:
                    self.key.emit(k.vkCode, k.scanCode, wparam in (WM_KEYDOWN, WM_SYSKEYDOWN), k.flags)
                    return 1                    # the game does not get it
            return user32.CallNextHookEx(None, code, wparam, ctypes.c_void_p(lparam))
        self._cb = proto(cb)
        hook = ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_int, proto, ctypes.c_void_p, wt.DWORD)(
            ("SetWindowsHookExW", user32))
        hook(WH_KEYBOARD_LL, self._cb, None, 0)
        msg = wt.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))

    # --- the GUI thread
    def start(self, widget):
        old = self.target
        self.target = widget
        widget.setFocus(QtCore.Qt.MouseFocusReason)
        self.lost = False
        if old is not widget:
            if old is not None:
                self._unwatch(old)
            widget.installEventFilter(self)
            self.flush()
            self.leaving = old
            _focus(widget, QtCore.QEvent.FocusIn)
            trace(f"into {name(widget)}")
        for vk in (VK_SHIFT, VK_CONTROL, VK_MENU):
            self.state[vk] = 0
        self.state[VK_CAPITAL] = user32.GetKeyState(VK_CAPITAL) & 1
        if not self.active:
            self.active = True
            self.changed.emit(True)

    def stop(self, later=False):
        """Typing ends; later (a mouse press): the field hears it at the release (flush)."""
        if self.target is not None:
            trace(f"ends in {name(self.target)}" + (" (at the release)" if later else ""))
            self.flush()
            self.leaving = self.target
            if not later:
                self.flush()
        if self.active:
            self.active = False
            self.target = None
            self.changed.emit(False)
        if self.leaving is not None:
            self._unwatch(self.leaving)
        self.target = None

    def _unwatch(self, widget):
        import shiboken6
        if shiboken6.isValid(widget):
            widget.removeEventFilter(self)

    def eventFilter(self, obj, ev):
        """The field typed into lost its focus without us (another program in front, a popup closed): noted; it
        gets it back as soon as the game is in front (refocus)."""
        if ev.type() == QtCore.QEvent.FocusOut and obj is self.target and not SENDING[0]:
            self.lost = True
            trace(f"the field lost its focus by itself ({ev.reason()}): {name(obj)}")
            QtCore.QTimer.singleShot(0, self.refocus)
        return False

    def refocus(self):
        """The field typed into gets its focus back (its caret blinks again) - while the game is the window in front;
        else later (the editor calls this when the game comes back)."""
        import shiboken6
        t = self.target
        if not getattr(self, "lost", False) or t is None or not shiboken6.isValid(t) or not t.isVisible():
            return
        if self.owner and _GetForegroundWindow() != self.owner():
            return                              # not yet: when the game is in front again
        self.lost = False
        t.setFocus(QtCore.Qt.OtherFocusReason)
        _focus(t, QtCore.QEvent.FocusIn)
        trace(f"its focus back: {name(t)}")

    def flush(self):
        """The field left (a mouse press before) hears it now: its caret goes, its selection goes, it finishes."""
        left, self.leaving = self.leaving, None
        if left is not None and left is not self.target:
            trace(f"out of {name(left)}")
            _focus(left, QtCore.QEvent.FocusOut)

    def _elsewhere(self):
        import time
        if time.time() - self._elsewhere_said > 5:    # (once in a while, not per key)
            self._elsewhere_said = time.time()
            buf = ctypes.create_unicode_buffer(120)
            user32.GetWindowTextW(ctypes.c_void_p(_GetForegroundWindow()), buf, 120)
            trace(f"keys while typing, but the game is not in front ({buf.value!r}): they stay with that window")

    def _modifiers(self):
        m = QtCore.Qt.NoModifier
        if self.state[VK_SHIFT] & 0x80:
            m |= QtCore.Qt.ShiftModifier
        if self.state[VK_CONTROL] & 0x80:
            m |= QtCore.Qt.ControlModifier
        if self.state[VK_MENU] & 0x80:
            m |= QtCore.Qt.AltModifier
        return m

    def _deliver(self, vk, scan, down, flags):
        if flags & LLKHF_INJECTED and not getattr(self, "_remote_said", False):
            self._remote_said = True
            trace("keys of a remote session (injected, Moonlight/Sunshine) go to the field")
        side = SIDES.get(vk, vk)
        if side in (VK_SHIFT, VK_CONTROL, VK_MENU):
            self.state[side] = 0x80 if down else 0
            self.state[vk] = 0x80 if down else 0
        if vk == VK_CAPITAL and down:
            self.state[VK_CAPITAL] ^= 1
        if vk == VK_ESCAPE:
            if down:
                self.stop()
            return
        if not self.target:
            return
        if 0x41 <= vk <= 0x5A:
            qkey = Q.Key_A + (vk - 0x41)
        elif 0x30 <= vk <= 0x39:
            qkey = Q.Key_0 + (vk - 0x30)
        elif 0x60 <= vk <= 0x69:
            qkey = Q.Key_0 + (vk - 0x60)
        else:
            qkey = SPECIAL.get(side, Q.Key_unknown)
        text = ""
        if down and not self.state[VK_CONTROL] & 0x80:
            buf = ctypes.create_unicode_buffer(8)
            n = _ToUnicodeEx(vk, scan, ctypes.addressof(self.state), buf, 8, 0, _GetKeyboardLayout(0))
            if n > 0 and buf.value.isprintable():
                text = buf.value[:n]
        if qkey == Q.Key_unknown and text:
            qkey = ord(text.upper()[0])
        ev = QtGui.QKeyEvent(QtCore.QEvent.KeyPress if down else QtCore.QEvent.KeyRelease, qkey, self._modifiers(),
                             text)
        # the widget holding the focus inside the panel (the panel may move it, e.g. Down: search -> results)
        import shiboken6
        if not shiboken6.isValid(self.target) or not self.target.isVisible():
            trace(f"the field is gone (built anew or closed) - a key went nowhere: {name(self.target)}")
            self.stop()                         # the field was rebuilt or closed: the keys are the game's again
            return
        target = self.target.window().focusWidget() or self.target
        if not shiboken6.isValid(target):
            target = self.target
        if target is not self.target and down:
            trace(f"a key went to {name(target)}, not to the field clicked {name(self.target)}")
        QtWidgets.QApplication.sendEvent(target, ev)

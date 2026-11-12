#!/usr/bin/env python3
"""Drive the X11 pointer and read/set input focus from a test.

    scripts/x11-input.py warp 1 500           # move the pointer (hover-to-open)
    scripts/x11-input.py click 130 400        # move, then press+release button 1
    scripts/x11-input.py focus                # print the focused window id
    scripts/x11-input.py setfocus 0x1e00004   # focus a window explicitly
    scripts/x11-input.py key alt+c            # press a chord (modifiers held)

Uses libX11 for the warp/focus calls and XTEST (libXtst) for the click, so it
works with no xdotool/xte/xwit installed on the box.

`focus` exists so a test can prove a panel did not steal focus: set focus to a
decoy window, click the app, read focus again — an app that grabs the
foreground (or is focusable when it should not be) changes the answer.
"""
import ctypes
import ctypes.util
import sys
import time


def _lib(name: str) -> ctypes.CDLL:
    return ctypes.CDLL(ctypes.util.find_library(name) or f"lib{name}.so.6")


def _open_x11() -> tuple[ctypes.CDLL, int]:
    x11 = _lib("X11")
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    dpy = x11.XOpenDisplay(None)
    if not dpy:
        print("cannot open X display", file=sys.stderr)
        raise SystemExit(1)
    x11.XWarpPointer.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
        ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
        ctypes.c_int, ctypes.c_int,
    ]
    return x11, dpy


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    action = sys.argv[1]
    x11, dpy = _open_x11()

    if action in ("warp", "click"):
        if len(sys.argv) != 4:
            print(__doc__, file=sys.stderr)
            return 2
        x, y = int(sys.argv[2]), int(sys.argv[3])
        root = x11.XDefaultRootWindow(dpy)
        x11.XWarpPointer(dpy, 0, root, 0, 0, 0, 0, x, y)
        x11.XFlush(dpy)
        if action == "click":
            xtst = _lib("Xtst")
            xtst.XTestFakeButtonEvent.argtypes = [
                ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong,
            ]
            # Let the app see the move first: hover-open and the click handler
            # are separate frames, and a click-through window ignores the first.
            time.sleep(0.4)
            xtst.XTestFakeButtonEvent(dpy, 1, True, 0)
            x11.XFlush(dpy)
            time.sleep(0.08)
            xtst.XTestFakeButtonEvent(dpy, 1, False, 0)
            x11.XFlush(dpy)
        print(f"{action} at {x},{y}")

    elif action == "focus":
        focus = ctypes.c_ulong()
        revert = ctypes.c_int()
        x11.XGetInputFocus.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
        ]
        x11.XGetInputFocus(dpy, ctypes.byref(focus), ctypes.byref(revert))
        print(f"0x{focus.value:x}")

    elif action == "setfocus":
        if len(sys.argv) != 3:
            print(__doc__, file=sys.stderr)
            return 2
        win = int(sys.argv[2], 0)
        # revert_to = RevertToParent, time = CurrentTime
        x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        x11.XSetInputFocus(dpy, win, 2, 0)
        x11.XFlush(dpy)
        print(f"focused 0x{win:x}")

    elif action == "key":
        if len(sys.argv) != 3:
            print(__doc__, file=sys.stderr)
            return 2
        combo = sys.argv[2].split("+")
        x11.XStringToKeysym.restype = ctypes.c_ulong
        x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
        x11.XKeysymToKeycode.restype = ctypes.c_ubyte
        x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        xtst = _lib("Xtst")
        xtst.XTestFakeKeyEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong,
        ]

        special = {"alt": "Alt_L", "ctrl": "Control_L", "control": "Control_L", "shift": "Shift_L", "super": "Super_L"}
        codes: list[int] = []
        for part in combo:
            name = special.get(part.lower(), part)
            keysym = x11.XStringToKeysym(name.encode())
            if not keysym:
                print(f"unknown key: {part}", file=sys.stderr)
                return 2
            code = x11.XKeysymToKeycode(dpy, keysym)
            if not code:
                print(f"no keycode for: {part}", file=sys.stderr)
                return 2
            codes.append(code)

        for code in codes:                      # press modifiers, then the key
            xtst.XTestFakeKeyEvent(dpy, code, True, 0)
            x11.XFlush(dpy)
            time.sleep(0.03)
        for code in reversed(codes):            # release in reverse order
            xtst.XTestFakeKeyEvent(dpy, code, False, 0)
            x11.XFlush(dpy)
            time.sleep(0.03)
        print(f"key {sys.argv[2]}")

    else:
        print(f"unknown action: {action}", file=sys.stderr)
        return 2

    x11.XCloseDisplay(dpy)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

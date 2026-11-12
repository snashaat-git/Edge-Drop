#!/usr/bin/env python3
"""Drive the X11 pointer from a test: warp it, or click with it.

    scripts/x11-input.py warp 1 500      # move the pointer (hover-to-open)
    scripts/x11-input.py click 180 170   # move, then press+release button 1

Uses libX11 for the warp and XTEST (libXtst) for the click, so it works with no
xdotool/xte installed on the box.
"""
import ctypes
import ctypes.util
import sys
import time


def _load(name: str) -> ctypes.CDLL:
    path = ctypes.util.find_library(name) or f"lib{name}.so.6"
    lib = ctypes.CDLL(path)
    lib.XOpenDisplay.restype = ctypes.c_void_p
    lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
    lib.XDefaultRootWindow.restype = ctypes.c_ulong
    lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    lib.XFlush.argtypes = [ctypes.c_void_p]
    lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    return lib


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    action, x, y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    if action not in ("warp", "click"):
        print(f"unknown action: {action}", file=sys.stderr)
        return 2

    x11 = _load("X11")
    dpy = x11.XOpenDisplay(None)
    if not dpy:
        print("cannot open X display", file=sys.stderr)
        return 1
    root = x11.XDefaultRootWindow(dpy)

    x11.XWarpPointer.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
        ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
        ctypes.c_int, ctypes.c_int,
    ]
    x11.XWarpPointer(dpy, 0, root, 0, 0, 0, 0, x, y)
    x11.XFlush(dpy)

    if action == "click":
        xtst = ctypes.CDLL(ctypes.util.find_library("Xtst") or "libXtst.so.6")
        xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        # Let the app see the move first: hover-open and click handlers are
        # separate frames in every shelf implementation.
        time.sleep(0.4)
        xtst.XTestFakeButtonEvent(dpy, 1, True, 0)
        x11.XFlush(dpy)
        time.sleep(0.08)
        xtst.XTestFakeButtonEvent(dpy, 1, False, 0)
        x11.XFlush(dpy)

    x11.XCloseDisplay(dpy)
    print(f"{action} at {x},{y}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

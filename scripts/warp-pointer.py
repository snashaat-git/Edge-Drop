#!/usr/bin/env python3
"""Warp the X11 pointer to (x, y) on the root window via ctypes + libX11.

Used by scripts/linux-smoke.sh to trigger hover-to-open when xdotool is absent.
    scripts/warp-pointer.py 1 500     # left edge, mid screen -> shelf opens
    scripts/warp-pointer.py 800 500   # away            -> shelf closes
"""
import ctypes
import ctypes.util
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    x, y = int(sys.argv[1]), int(sys.argv[2])

    libx11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
    libx11.XOpenDisplay.restype = ctypes.c_void_p
    libx11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    libx11.XDefaultRootWindow.restype = ctypes.c_ulong
    libx11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    libx11.XWarpPointer.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
        ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
        ctypes.c_int, ctypes.c_int,
    ]
    libx11.XFlush.argtypes = [ctypes.c_void_p]
    libx11.XCloseDisplay.argtypes = [ctypes.c_void_p]

    dpy = libx11.XOpenDisplay(None)
    if not dpy:
        print("cannot open X display", file=sys.stderr)
        return 1
    root = libx11.XDefaultRootWindow(dpy)
    libx11.XWarpPointer(dpy, 0, root, 0, 0, 0, 0, x, y)
    libx11.XFlush(dpy)
    libx11.XCloseDisplay(dpy)
    print(f"warped to {x},{y}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

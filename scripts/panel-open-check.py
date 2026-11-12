#!/usr/bin/env python3
"""Exit 0 when a screenshot shows the Edge-Drop shelf panel open.

Under Xvfb the root window is black and the only client is the app, so "lit
pixels in the left band" means the panel is up. Used by the pin and hotkey
cases, where a frame is the only evidence of "still painted" or "retracted".

    scripts/panel-open-check.py /tmp/edge-drop-hotkey.png

Decoding is delegated to ffmpeg and only stdlib is used, on purpose: Pillow is
not installed everywhere this runs (the CI runner has no Pillow, and a harness
that resets PATH can pick a different interpreter than the developer's shell —
which failed a case with `ModuleNotFoundError: No module named 'PIL'` instead of
a wrong measurement).
"""
import subprocess
import sys

BAND_WIDTH = 320
LIT_THRESHOLD = 500  # pixels brighter than ~8/255 luminance


def frame_size(path: str) -> tuple[int, int]:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", path],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    width, height = out.split("x")[:2]
    return int(width), int(height)


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/edge-drop-hotkey.png"
    width, height = frame_size(path)
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo",
         "-pix_fmt", "rgb24", "-"],
        capture_output=True, check=True,
    ).stdout

    band = min(BAND_WIDTH, width)
    lit = 0
    stride = width * 3
    for y in range(height):
        row = raw[y * stride: y * stride + band * 3]
        for x in range(0, len(row), 3):
            r, g, b = row[x], row[x + 1], row[x + 2]
            if (299 * r + 587 * g + 114 * b) // 1000 > 8:
                lit += 1

    print(f"{lit} lit pixels in the left {band}px of {width}x{height}")
    return 0 if lit > LIT_THRESHOLD else 1


if __name__ == "__main__":
    raise SystemExit(main())

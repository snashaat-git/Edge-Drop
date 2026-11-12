#!/usr/bin/env python3
"""Exit 0 when a screenshot shows the Edge-Drop shelf panel open.

Under Xvfb the root window is black and the only client is the app, so "lit
pixels in the left band" means the panel is up. Used by the hotkey case, where
there is no store write or log line to assert on.

    scripts/panel-open-check.py /tmp/edge-drop-hotkey.png
"""
import sys

from PIL import Image

BAND_WIDTH = 320
LIT_THRESHOLD = 500  # pixels brighter than ~8/255 per channel


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/edge-drop-hotkey.png"
    image = Image.open(path).convert("RGB")
    width, height = image.size
    band = image.crop((0, 0, min(BAND_WIDTH, width), height)).convert("L")
    # Luminance histogram: everything above 8/255 counts as "lit". Avoids
    # Image.getdata(), which is deprecated in Pillow 14.
    lit = sum(band.histogram()[9:])
    print(f"{lit} lit pixels in the left {BAND_WIDTH}px of {width}x{height}")
    return 0 if lit > LIT_THRESHOLD else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
# Linux smoke harness for the Edge-Drop port.
#
#   scripts/linux-smoke.sh <case>        case = text | image | files | hover
#
# Runs the app under Xvfb, puts known content on the clipboard, warps the
# pointer to the left edge so the shelf opens, then asserts against the app's
# own store (~/.config/edge-drop/items.json) instead of trusting a screenshot.
#
# Exit code: 0 when the expected data kind was captured, 1 when it was not.
# Artifacts: /tmp/edge-drop-<case>.png, /tmp/edge-drop-smoke.log
#
# Packaged build: EDGE_DROP_BIN=dist/Edge-Drop-0.4.0.AppImage scripts/linux-smoke.sh text
# (an AppImage without FUSE needs --appimage-extract-and-run; put that in EDGE_DROP_BIN_ARGS)
set -u

CASE="${1:-text}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="${HOME}/.config/edge-drop/items.json"
LOG=/tmp/edge-drop-smoke.log
SHOT_XWD="/tmp/edge-drop-${CASE}.xwd"
SHOT_PNG="/tmp/edge-drop-${CASE}.png"

BIN="${EDGE_DROP_BIN:-}"
if [ -n "$BIN" ]; then
  LAUNCH="$BIN ${EDGE_DROP_BIN_ARGS:-}"
else
  LAUNCH="./node_modules/.bin/electron . --no-sandbox"
fi

# --- probe fixtures -------------------------------------------------------
# A 120x80 PNG, generated once; used by the image and files cases.
if [ ! -f /tmp/probe.png ]; then
  python3 - <<'PY'
import zlib, struct
def png(w, h, rgb):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
open('/tmp/probe.png', 'wb').write(png(120, 80, (200, 40, 90)))
PY
fi

command -v xclip >/dev/null || { echo "xclip missing: sudo apt install xclip"; exit 1; }
command -v xwd   >/dev/null || { echo "xwd missing: sudo apt install x11-apps"; exit 1; }

rm -f "$STORE"

INNER="$(mktemp /tmp/edge-drop-inner.XXXXXX.sh)"
cat > "$INNER" <<INNEREOF
#!/usr/bin/env bash
set -u
cd "$ROOT"
$LAUNCH > "$LOG" 2>&1 &
APP=\$!
# Let the app settle: first paint, store load, watcher seed.
sleep 16
case "$CASE" in
  text)  printf 'linux clipboard probe 12345' | xclip -selection clipboard ;;
  image) xclip -selection clipboard -t image/png -i /tmp/probe.png ;;
  files) printf 'file:///tmp/probe.png\r\n' | xclip -selection clipboard -t text/uri-list ;;
  hover) : ;;
  *) echo "unknown case: $CASE" >&2 ;;
esac
sleep 5
python3 "$ROOT/scripts/warp-pointer.py" 1 500
sleep 4
xwd -root -silent > "$SHOT_XWD"
kill \$APP 2>/dev/null
wait \$APP 2>/dev/null
INNEREOF
chmod +x "$INNER"

xvfb-run -a --server-args="-screen 0 1600x1000x24" "$INNER"
rm -f "$INNER"

if command -v ffmpeg >/dev/null; then
  ffmpeg -y -loglevel error -i "$SHOT_XWD" "$SHOT_PNG" && echo "screenshot: $SHOT_PNG"
fi

echo "--- store ---"
head -c 800 "$STORE" 2>/dev/null || echo "(no store written)"
echo
echo "--- log (updater noise filtered) ---"
grep -v -e "dev-app-update.yml" -e "^Checking for update" "$LOG" 2>/dev/null | tail -25

case "$CASE" in
  text)  WANT='"kind":"text"' ;;
  image) WANT='"kind":"image"' ;;
  files) WANT='"kind":"files"' ;;
  hover) WANT='' ;;
  *)     WANT='' ;;
esac

if [ -z "$WANT" ]; then
  echo "RESULT: screenshot only ($SHOT_PNG)"
  exit 0
fi

if grep -q "$WANT" "$STORE" 2>/dev/null; then
  echo "RESULT: PASS — captured $WANT"
  exit 0
fi
echo "RESULT: FAIL — store has no $WANT"
exit 1

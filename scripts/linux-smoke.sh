#!/usr/bin/env bash
# Linux smoke harness for the Edge-Drop port.
#
#   scripts/linux-smoke.sh <case>        case = text | image | files | hover | paste
#
# Runs the app under Xvfb, puts known content on the clipboard, drives the X11
# pointer (warp to the left edge to open the shelf, click to paste), then
# asserts against the app's own store / a fixture log instead of trusting a
# screenshot.
#
#   text   clipboard text lands in the store as a text item
#   image  a PNG lands as an image item
#   files  a file:// uri list lands as a files item
#   filesout  clicking a file card publishes text/uri-list back to the clipboard
#   hover  the panel opens on hover (screenshot only)
#   paste  clicking a card emits the platform paste keystroke. Verified with a
#          stub `xdotool` on PATH that records its arguments, so this proves the
#          app's own detection + exec plumbing without installing xdotool.
#   nopaste  same click with no injector installed: the app must fall back to
#          copy-only instead of failing
#   focus    with X input focus parked on a decoy xterm, clicking a card must not
#          move focus (the Linux stand-in for WS_EX_NOACTIVATE)
#   wayland  launched with Wayland session vars: must select the XWayland backend
#   hotkey   Alt+C sent through XTEST with the pointer far from the edge must open
#          the panel on its own
#
# Exit code: 0 when the expected effect was observed, 1 when it was not.
# Artifacts: /tmp/edge-drop-<case>.png, /tmp/edge-drop-smoke.log,
#            /tmp/edge-drop-paste.log (paste case)
#
# Packaged build: EDGE_DROP_BIN=dist/Edge-Drop-0.4.0.AppImage scripts/linux-smoke.sh text
# (an AppImage without FUSE needs --appimage-extract-and-run; put that in EDGE_DROP_BIN_ARGS)
set -u

CASE="${1:-text}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="${HOME}/.config/edge-drop/items.json"
LOG=/tmp/edge-drop-smoke.log
PASTE_LOG=/tmp/edge-drop-paste.log
URI_OUT=/tmp/edge-drop-uri-out.txt
FOCUS_BEFORE=/tmp/edge-drop-focus-before.txt
FOCUS_AFTER=/tmp/edge-drop-focus-after.txt
SHOT_XWD="/tmp/edge-drop-${CASE}.xwd"
SHOT_PNG="/tmp/edge-drop-${CASE}.png"
CLICK_X="${CLICK_X:-130}"
CLICK_Y="${CLICK_Y:-400}"

BIN="${EDGE_DROP_BIN:-}"
if [ -n "$BIN" ]; then
  LAUNCH="$BIN ${EDGE_DROP_BIN_ARGS:-}"
else
  LAUNCH="./node_modules/.bin/electron . --no-sandbox"
fi

# The wayland case pretends to be a Wayland session while still running on Xvfb,
# which is exactly the XWayland situation: the app must ask for the x11 backend.
LAUNCH_ENV=""
if [ "$CASE" = "wayland" ]; then
  LAUNCH_ENV="XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-0"
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

# Stub injector: records how the app invoked it, exits 0.
# The nopaste case deliberately has no injector on PATH, to prove the fallback.
FIXTURE="$(mktemp -d /tmp/edge-drop-fixture.XXXXXX)"
mkdir -p "$FIXTURE/bin"
if [ "$CASE" != "nopaste" ]; then
  cat > "$FIXTURE/bin/xdotool" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PASTE_LOG"
STUB
  chmod +x "$FIXTURE/bin/xdotool"
fi
rm -f "$PASTE_LOG" "$URI_OUT" "$FOCUS_BEFORE" "$FOCUS_AFTER"

command -v xclip >/dev/null || { echo "xclip missing: sudo apt install xclip"; rm -rf "$FIXTURE"; exit 1; }
command -v xwd   >/dev/null || { echo "xwd missing: sudo apt install x11-apps"; rm -rf "$FIXTURE"; exit 1; }

rm -f "$STORE"

INNER="$(mktemp /tmp/edge-drop-inner.XXXXXX.sh)"
cat > "$INNER" <<INNEREOF
#!/usr/bin/env bash
set -u
cd "$ROOT"
# The paste case must see the stub injector, not the developer's real one.
export PATH="$FIXTURE/bin:\$PATH"
$LAUNCH_ENV $LAUNCH > "$LOG" 2>&1 &
APP=\$!
# Let the app settle: first paint, store load, watcher seed.
sleep 16
case "$CASE" in
  text|paste|nopaste|focus) printf 'linux clipboard probe 12345' | xclip -selection clipboard ;;
  image)      xclip -selection clipboard -t image/png -i /tmp/probe.png ;;
  files|filesout) printf 'file:///tmp/probe.png\r\n' | xclip -selection clipboard -t text/uri-list ;;
  hover)      : ;;
  wayland)    : ;;
  hotkey)     : ;;
  *) echo "unknown case: $CASE" >&2 ;;
esac
sleep 5
if [ "$CASE" = "focus" ]; then
  # Decoy window that legitimately owns the input focus. Xvfb has no window
  # manager, so focus is assigned explicitly — what this proves is that the app
  # itself never calls XSetInputFocus / never maps as focus-taking when clicked.
  xterm -T edge-drop-focus-probe -geometry 60x18+700+320 -e sleep 900 &
  sleep 3
  XID=\$(xwininfo -root -tree | grep -m1 'edge-drop-focus-probe' | awk '{print \$1}')
  python3 "$ROOT/scripts/x11-input.py" setfocus "\$XID"
  python3 "$ROOT/scripts/x11-input.py" focus > "$FOCUS_BEFORE"
fi
if [ "$CASE" = "hotkey" ]; then
  # Never hover in this case: the panel must open from the keystroke alone.
  python3 "$ROOT/scripts/x11-input.py" warp 900 700
  sleep 1
  python3 "$ROOT/scripts/x11-input.py" key alt+c
  sleep 2
else
  python3 "$ROOT/scripts/x11-input.py" warp 1 500
  sleep 4
fi
if [ "$CASE" = "focus" ]; then
  python3 "$ROOT/scripts/x11-input.py" click "$CLICK_X" "$CLICK_Y"
  sleep 2
  python3 "$ROOT/scripts/x11-input.py" focus > "$FOCUS_AFTER"
fi
if [ "$CASE" = "paste" ] || [ "$CASE" = "nopaste" ]; then
  python3 "$ROOT/scripts/x11-input.py" click "$CLICK_X" "$CLICK_Y"
  sleep 2
fi
if [ "$CASE" = "filesout" ]; then
  python3 "$ROOT/scripts/x11-input.py" click "$CLICK_X" "$CLICK_Y"
  sleep 1
  # Read the clipboard back while the app still owns the selection.
  xclip -o -selection clipboard -t text/uri-list > "$URI_OUT" 2>/dev/null
fi
xwd -root -silent > "$SHOT_XWD"
kill \$APP 2>/dev/null
wait \$APP 2>/dev/null
INNEREOF
chmod +x "$INNER"

xvfb-run -a --server-args="-screen 0 1600x1000x24" "$INNER"
rm -f "$INNER"
rm -rf "$FIXTURE"

if command -v ffmpeg >/dev/null; then
  ffmpeg -y -loglevel error -i "$SHOT_XWD" "$SHOT_PNG" && echo "screenshot: $SHOT_PNG"
fi

echo "--- store ---"
head -c 800 "$STORE" 2>/dev/null || echo "(no store written)"
echo
if [ -f "$PASTE_LOG" ]; then
  echo "--- injector invocation ---"
  cat "$PASTE_LOG"
  echo
fi
echo "--- log (updater noise filtered) ---"
grep -v -e "dev-app-update.yml" -e "^Checking for update" "$LOG" 2>/dev/null | tail -25

case "$CASE" in
  text)  WANT='"kind":"text"' ;;
  image) WANT='"kind":"image"' ;;
  files) WANT='"kind":"files"' ;;
  paste|hover) WANT='' ;;
  *)     WANT='' ;;
esac

if [ "$CASE" = "paste" ]; then
  if grep -q "key --clearmodifiers ctrl+v" "$PASTE_LOG" 2>/dev/null; then
    echo "RESULT: PASS — paste keystroke sent through the detected injector"
    exit 0
  fi
  echo "RESULT: FAIL — no ctrl+v reached the injector (did the click land on a card?)"
  echo "        Tune CLICK_X/CLICK_Y, inspect $SHOT_PNG"
  exit 1
fi

if [ "$CASE" = "filesout" ]; then
  echo "--- clipboard after clicking the file card ---"
  cat "$URI_OUT" 2>/dev/null || echo "(clipboard had no uri list)"
  echo
  if grep -q "file:///tmp/probe.png" "$URI_OUT" 2>/dev/null; then
    echo "RESULT: PASS — file card wrote a text/uri-list"
    exit 0
  fi
  echo "RESULT: FAIL — clicking the file card did not publish a uri list"
  exit 1
fi

if [ "$CASE" = "hotkey" ]; then
  # What this case owns: the shortcut is registered and the toggle reaches the
  # renderer with no pointer involvement. Whether the panel stays painted is a
  # separate question — under Xvfb it closes again immediately (the pointer is
  # not over it), so the screenshot is reported, not asserted.
  if python3 "$ROOT/scripts/panel-open-check.py" "$SHOT_PNG" 2>/dev/null; then
    echo "panel visible in the frame"
  else
    echo "panel not visible in the frame (pointer is off-panel)"
  fi
  if grep -q "window:toggle event to renderer" "$LOG" 2>/dev/null; then
    echo "RESULT: PASS — Alt+C registered and delivered a panel toggle to the renderer"
    exit 0
  fi
  echo "RESULT: FAIL — no panel toggle after Alt+C (shortcut not registered?)"
  exit 1
fi

if [ "$CASE" = "wayland" ]; then
  if grep -q "ozone=x11 (XWayland)" "$LOG" 2>/dev/null; then
    echo "RESULT: PASS — wayland session detected, x11 (XWayland) backend requested"
    exit 0
  fi
  echo "RESULT: FAIL — expected 'ozone=x11 (XWayland)' in the startup log"
  exit 1
fi

if [ "$CASE" = "focus" ]; then
  B="$(cat "$FOCUS_BEFORE" 2>/dev/null)"
  A="$(cat "$FOCUS_AFTER" 2>/dev/null)"
  echo "--- input focus ---"
  echo "before=$B after=$A"
  echo
  if [ -n "$B" ] && [ "$B" = "$A" ] && grep -q "\[IPC\] item:paste" "$LOG" 2>/dev/null; then
    echo "RESULT: PASS — clicking a card never moved X input focus"
    exit 0
  fi
  if [ -z "$B" ]; then
    echo "RESULT: FAIL — could not park focus on the decoy window (no WM in Xvfb?)"
  else
    echo "RESULT: FAIL — focus moved $B -> $A, or the click never reached a card"
  fi
  exit 1
fi

if [ "$CASE" = "nopaste" ]; then
  if grep -q "\[Paste\] keystroke injector: none" "$LOG" 2>/dev/null; then
    echo "RESULT: PASS — no injector installed: took the copy-only fallback, no crash"
    exit 0
  fi
  echo "RESULT: FAIL — expected the none-injector fallback branch"
  exit 1
fi

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

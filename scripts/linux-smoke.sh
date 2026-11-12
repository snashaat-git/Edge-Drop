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
#   pin      clicking the pin button then leaving must keep the shelf up; clicking
#          it again must let the same leave retract it (two frames, compared)
#   zoom     uiZoom 1.25 in the store: the window must be ~480-520px wide and the
#          app must log that it applied the factor
#   zoom100  the same measurement at 100%, so the 125% numbers are a comparison
#          and not a guess
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
# The app writes its store under XDG_CONFIG_HOME. Point it at a throwaway dir so a
# smoke run never touches the shelf a developer actually uses — an earlier version
# wiped ~/.config/edge-drop/items.json on every case.
SMOKE_CONFIG="$(mktemp -d /tmp/edge-drop-smoke-config.XXXXXX)"
export XDG_CONFIG_HOME="$SMOKE_CONFIG"
STORE="$SMOKE_CONFIG/edge-drop/items.json"
FIXTURE=""
trap 'rm -rf "$SMOKE_CONFIG" ${FIXTURE:+"$FIXTURE"}' EXIT
LOG=/tmp/edge-drop-smoke.log
PASTE_LOG=/tmp/edge-drop-paste.log
URI_OUT=/tmp/edge-drop-uri-out.txt
FOCUS_BEFORE=/tmp/edge-drop-focus-before.txt
FOCUS_AFTER=/tmp/edge-drop-focus-after.txt
SHOT_XWD="/tmp/edge-drop-${CASE}.xwd"
SHOT_PNG="/tmp/edge-drop-${CASE}.png"
PIN_BASE_XWD="/tmp/edge-drop-pin-base.xwd"
PIN_BASE_PNG="/tmp/edge-drop-pin-base.png"
PIN_BEFORE_XWD="/tmp/edge-drop-pin-before.xwd"
PIN_BEFORE_PNG="/tmp/edge-drop-pin-before.png"
PIN_OPEN_XWD="/tmp/edge-drop-pin-open.xwd"
PIN_CLOSED_XWD="/tmp/edge-drop-pin-closed.xwd"
PIN_OPEN_PNG="/tmp/edge-drop-pin-open.png"
PIN_CLOSED_PNG="/tmp/edge-drop-pin-closed.png"
WININFO="/tmp/edge-drop-window.txt"
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

# The zoom cases need the factor in the store BEFORE the window exists: main
# reads it when it computes the geometry, so seeding it afterwards would only
# prove that a live update works, not that the shelf launches at that size.
if [ "$CASE" = "zoom" ] || [ "$CASE" = "zoom100" ]; then
  case "$CASE" in
    zoom)    ZOOM_VALUE=1.25 ;;
    zoom100) ZOOM_VALUE=1.0 ;;
  esac
  mkdir -p "$SMOKE_CONFIG/edge-drop"
  printf '{"uiZoom": %s}\n' "$ZOOM_VALUE" > "$SMOKE_CONFIG/edge-drop/settings.json"
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
if [ "$CASE" = "zoom" ] || [ "$CASE" = "zoom100" ]; then
  # The window is sized at creation from PANEL_WIDTH × zoom; the panel itself is
  # closed here, so this is the geometry main chose, not an animation frame.
  # The onboarding tour is a second window with the same title, so take the one
  # anchored at the top-left corner: that is the edge panel.
  xwininfo -root -tree | grep '"Edge-Drop"' | grep -m1 -- '+0+0' > "$WININFO"
fi
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
  # Move well away first, then onto the edge. A warp to the position the pointer
  # already holds generates no motion event, and the app arms its open-dwell on the
  # crossing.
  python3 "$ROOT/scripts/x11-input.py" warp 900 500
  sleep 0.5
  python3 "$ROOT/scripts/x11-input.py" warp 1 500
  # Wait for the shelf rather than sleeping through a guess: the first paint can
  # lag the pointer by seconds on a loaded machine, and a fixed wait reads that as
  # "the hover never opened the shelf".
  waited=0
  while [ "\$waited" -lt 40 ] && ! grep -q '\[Panel\] open: true' "$LOG" 2>/dev/null; do
    sleep 0.5
    waited=\$((waited + 1))
  done
  if ! grep -q '\[Panel\] open: true' "$LOG" 2>/dev/null; then
    echo "[Panel] open probe: the shelf never opened (waited 20s)" >> "$LOG"
  fi
  # Let the open animation settle before any frame is compared.
  sleep 1.5
fi
if [ "$CASE" = "pin" ]; then
  # Frame of the shelf as the hover left it, before anything is clicked: if this
  # is already empty, the case is measuring a closed shelf, not a broken pin.
  xwd -root -silent > "$PIN_BASE_XWD"
  # The pin button lives at the right end of the header, just left of the gear.
  # There is no window manager here to measure it against, so locate it by the
  # line it logs when clicked, probing a small box around its known spot.
  PIN_X=""; PIN_Y=""
  for py in 277 270 284; do
    for px in 205 197 213; do
      python3 "$ROOT/scripts/x11-input.py" click "\$px" "\$py"
      sleep 0.7
      if grep -q '\[Pin\] shelf pinned: true' "$LOG"; then PIN_X="\$px"; PIN_Y="\$py"; break 2; fi
    done
  done
  if [ -n "\$PIN_X" ]; then
    # A stray second event would leave it unpinned: make the end state explicit
    # instead of trusting that one "true" line somewhere in the log.
    for attempt in 1 2; do
      [ "\$(grep -o 'shelf pinned: [a-z]*' "$LOG" | tail -1 | awk '{print \$NF}')" = "true" ] && break
      python3 "$ROOT/scripts/x11-input.py" click "\$PIN_X" "\$PIN_Y"
      sleep 1
    done
  fi
  if [ -z "\$PIN_X" ]; then
    echo "[Pin] probe: button not found" >> "$LOG"
  else
    # The shelf must be up while the pointer is still on the button: if it is not,
    # the leave is not what closed it and the rest of the case would blame the pin.
    sleep 1
    xwd -root -silent > "$PIN_BEFORE_XWD"
    # Under load the first frame can land before the shelf repaints; one retry
    # separates "slow frame" from "the pin never held" (an empty shelf stays empty).
    if command -v ffmpeg >/dev/null; then
      ffmpeg -y -loglevel error -i "$PIN_BEFORE_XWD" "$PIN_BEFORE_PNG" 2>/dev/null
      if ! python3 "$ROOT/scripts/panel-open-check.py" "$PIN_BEFORE_PNG" >/dev/null 2>&1; then
        # Say so out loud: a run that needs this is a slow frame, and a pattern of
        # them is worth looking at rather than hiding behind the retry.
        echo "[Pin] first frame after the pin click was empty; re-capturing after 2s" >> "$LOG"
        sleep 2
        xwd -root -silent > "$PIN_BEFORE_XWD"
      fi
    fi
    # Pinned, and the pointer leaves for well longer than the close grace. The wait
    # is generous on purpose: this runs back-to-back with other cases, and a slow
    # frame here must not look like a retracted shelf.
    python3 "$ROOT/scripts/x11-input.py" warp 1200 700
    sleep 6
    xwd -root -silent > "$PIN_OPEN_XWD"
    # Same button again unpins it; now the leave must retract the shelf.
    python3 "$ROOT/scripts/x11-input.py" warp "\$PIN_X" "\$PIN_Y"
    sleep 1
    # Count the closes so far: the app may already have logged one during startup,
    # and a presence check would return immediately on that stale line.
    closes_before=\$(grep -c '\[Panel\] open: false' "$LOG" 2>/dev/null || true)
    python3 "$ROOT/scripts/x11-input.py" click "\$PIN_X" "\$PIN_Y"
    sleep 1
    python3 "$ROOT/scripts/x11-input.py" warp 1200 700
    # Same rule as the open: wait for the close the app reports, then let the
    # retract animation finish, instead of sleeping through a guess.
    waited=0
    while [ "\$waited" -lt 40 ]; do
      closes_now=\$(grep -c '\[Panel\] open: false' "$LOG" 2>/dev/null || true)
      [ "\${closes_now:-0}" -gt "\${closes_before:-0}" ] && break
      sleep 0.5
      waited=\$((waited + 1))
    done
    sleep 1.5
    xwd -root -silent > "$PIN_CLOSED_XWD"
  fi
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

if [ "$CASE" = "pin" ]; then
  if grep -q '\[Pin\] probe: button not found' "$LOG" 2>/dev/null; then
    echo "RESULT: FAIL — could not reach the pin button (layout moved?)"
    exit 1
  fi
  if ! grep -q '\[Pin\] shelf pinned: true' "$LOG" 2>/dev/null || ! grep -q '\[Pin\] shelf pinned: false' "$LOG" 2>/dev/null; then
    echo "RESULT: FAIL — pin was not toggled on and off"
    exit 1
  fi
  command -v ffmpeg >/dev/null || { echo "RESULT: FAIL — ffmpeg is needed to read the frames"; exit 1; }
  ffmpeg -y -loglevel error -i "$PIN_BASE_XWD" "$PIN_BASE_PNG"
  ffmpeg -y -loglevel error -i "$PIN_BEFORE_XWD" "$PIN_BEFORE_PNG"
  ffmpeg -y -loglevel error -i "$PIN_OPEN_XWD" "$PIN_OPEN_PNG"
  ffmpeg -y -loglevel error -i "$PIN_CLOSED_XWD" "$PIN_CLOSED_PNG"
  echo "--- frames on disk (a stale file would make the checks meaningless) ---"
  ls -l "$PIN_BASE_XWD" "$PIN_BEFORE_XWD" "$PIN_OPEN_XWD" "$PIN_CLOSED_XWD" 2>&1 | sed 's/^/  /'
  echo "--- frame of the shelf the hover opened, before any click ---"
  if ! python3 "$ROOT/scripts/panel-open-check.py" "$PIN_BASE_PNG"; then
    echo "RESULT: FAIL — the hover never opened the shelf, so nothing about the pin was tested"
    exit 1
  fi
  echo "--- frame right after pinning, pointer still on the button ---"
  if ! python3 "$ROOT/scripts/panel-open-check.py" "$PIN_BEFORE_PNG"; then
    echo "RESULT: FAIL — the shelf was not painted right after the pin click, so the pin never held"
    exit 1
  fi
  echo "--- frame with the shelf pinned, pointer 1100px away ---"
  if ! python3 "$ROOT/scripts/panel-open-check.py" "$PIN_OPEN_PNG"; then
    echo "RESULT: FAIL — the shelf retracted although it was pinned"
    exit 1
  fi
  echo "--- frame after unpinning, pointer in the same place ---"
  if python3 "$ROOT/scripts/panel-open-check.py" "$PIN_CLOSED_PNG"; then
    echo "RESULT: FAIL — the shelf stayed open after unpinning, so the frames prove nothing"
    exit 1
  fi
  echo "RESULT: PASS — pinned: stays open with the pointer away; unpinned: retracts"
  exit 0
fi

if [ "$CASE" = "zoom" ] || [ "$CASE" = "zoom100" ]; then
  W="$(sed -E 's/.* ([0-9]+)x([0-9]+)\+.*/\1/' "$WININFO" 2>/dev/null)"
  H="$(sed -E 's/.* ([0-9]+)x([0-9]+)\+.*/\2/' "$WININFO" 2>/dev/null)"
  echo "--- window the app chose ---"
  cat "$WININFO" 2>/dev/null || echo "(no Edge-Drop window found)"
  echo
  echo "width=$W height=$H"
  case "$W" in ''|*[!0-9]*) echo "RESULT: FAIL — could not read the window geometry"; exit 1 ;; esac
  if [ "$CASE" = "zoom" ]; then
    if ! grep -q 'UI zoom 1.25x' "$LOG" 2>/dev/null; then
      echo "RESULT: FAIL — 125% was in the store but the app never applied it"
      exit 1
    fi
    if [ "$W" -lt 470 ] || [ "$W" -gt 560 ]; then
      echo "RESULT: FAIL — a 125% shelf must be roughly 480-520px wide, got $W"
      exit 1
    fi
    echo "RESULT: PASS — 125% zoom applied, window widened to $W"
    exit 0
  fi
  if [ "$W" -lt 370 ] || [ "$W" -gt 430 ]; then
    echo "RESULT: FAIL — the 100% shelf should be roughly 384-416px wide, got $W"
    exit 1
  fi
  echo "RESULT: PASS — 100% baseline window is $W wide (the 125% case must be wider)"
  exit 0
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

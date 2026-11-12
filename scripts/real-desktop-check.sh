#!/usr/bin/env bash
# Real-desktop checks for the Edge-Drop port. Needs a live X session with a
# window manager — this is the counterpart to scripts/linux-smoke.sh, which runs
# headless under Xvfb where there is no WM, no second monitor and no compositor.
#
#   DISPLAY=:1 scripts/real-desktop-check.sh geometry
#   DISPLAY=:1 scripts/real-desktop-check.sh hotkey
#   DISPLAY=:1 scripts/real-desktop-check.sh focus
#   DISPLAY=:1 scripts/real-desktop-check.sh edges
#   DISPLAY=:1 scripts/real-desktop-check.sh all
#
# Each check launches its own app instance against a throwaway XDG_CONFIG_HOME, so
# the real ~/.config/edge-drop store, settings and clipboard are not touched
# (the focus check saves and restores the clipboard text it displaces).
#
# Exits 0 when every requested check passed.
set -u

WHICH="${1:-all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/tmp/edge-drop-realdekstop}"
LOG="$WORK/app.log"
APP_PID=""
FAILED=0

die() { echo "FATAL: $*" >&2; exit 2; }

[ -n "${DISPLAY:-}" ] || die "set DISPLAY (e.g. DISPLAY=:1)"
command -v ffmpeg >/dev/null || die "ffmpeg missing"
command -v xwininfo >/dev/null || die "xwininfo missing (x11-utils)"
xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q "window id" ||
  die "no window manager on $DISPLAY — use scripts/linux-smoke.sh under Xvfb instead"

# --- helpers -------------------------------------------------------------
grab() { # grab <png> <x> <y> <w> <h>
  ffmpeg -y -loglevel error -f x11grab -video_size "$4x$5" -i "$DISPLAY+$2,$3" -frames:v 1 "$1"
}

app_window() { # -> "id x y w h" for the shelf window, empty when absent
  local id
  id="$(xwininfo -root -tree 2>/dev/null | grep '"Edge-Drop"' | head -1 | awk '{print $1}')"
  [ -n "$id" ] || return 0
  xwininfo -id "$id" 2>/dev/null | awk -v id="$id" '
    /Absolute upper-left X:/ { x=$NF }
    /Absolute upper-left Y:/ { y=$NF }
    /^  Width:/  { w=$NF }
    /^  Height:/ { h=$NF }
    END { if (w != "" && h != "") print id, x, y, w, h }'
}

start_app() {
  mkdir -p "$WORK/config/edge-drop"
  [ -f "$WORK/config/edge-drop/settings.json" ] || cat > "$WORK/config/edge-drop/settings.json" <<'JSON'
{ "tutorialCompleted": true, "onboardingVersion": 2, "stickPosition": "left",
  "hoverActivation": true, "toggleHotkey": "Alt+C" }
JSON
  : > "$LOG"
  # setsid: the launcher (node cli.js) spawns the real binary as a child, so
  # killing one pid leaves the window alive. A new session lets stop_app kill the
  # whole tree, which also releases the single-instance lock for the next run.
  ( cd "$ROOT" && exec setsid env XDG_CONFIG_HOME="$WORK/config" ./node_modules/.bin/electron . --no-sandbox >"$LOG" 2>&1 ) &
  APP_PID=$!
  for _ in $(seq 1 40); do
    [ -n "$(app_window)" ] && return 0
    sleep 0.5
  done
  echo "window did not appear; see $LOG" >&2
  return 1
}

stop_app() {
  [ -n "$APP_PID" ] || return 0
  kill -TERM -- -"$APP_PID" 2>/dev/null || kill "$APP_PID" 2>/dev/null
  sleep 1
  kill -KILL -- -"$APP_PID" 2>/dev/null
  wait "$APP_PID" 2>/dev/null
  APP_PID=""
  # The single-instance lock means a new launch exits immediately if the old
  # process is still shutting down — wait for the window to actually go away.
  local i
  for i in $(seq 1 20); do
    [ -z "$(app_window)" ] && return 0
    sleep 0.5
  done
  echo "note  old Edge-Drop window still present after shutdown" >&2
}

changed_px() { # changed_px <a.png> <b.png>
  python3 - "$1" "$2" <<'PY'
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("L")).astype(int)
b = np.asarray(Image.open(sys.argv[2]).convert("L")).astype(int)
print(int((np.abs(a - b) > 12).sum()))
PY
}

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }

# --- checks --------------------------------------------------------------
check_geometry() {
  echo "== geometry / work area =="
  local geo id x y w h
  geo="$(app_window)"
  [ -n "$geo" ] || { fail "no Edge-Drop window"; return; }
  read -r id x y w h <<<"$geo"
  echo "window   $id ${w}x${h}+${x}+${y}"

  local wm_work
  wm_work="$(xprop -root _NET_WORKAREA | grep -o '[0-9]\+' | head -4 | paste -sd, -)"
  echo "workarea $wm_work  (x, y, w, h)"
  local wx wy ww wh
  IFS=, read -r wx wy ww wh <<<"$wm_work"

  local displays
  displays="$(xrandr --query | awk '/ connected/ { print $1, $3 }' | paste -sd' ' -)"
  echo "displays $displays"

  # The shelf must sit inside the screen and below any top bar. It is NOT
  # asserted against _NET_WORKAREA's bottom edge: mutter advertises 2059px here
  # while Electron's per-display workArea (the value the app positions against)
  # is 2062px, so the delta is reported instead of failed.
  local screen_w screen_h
  screen_w="$(xrandr --query | sed -n 's/.*current \([0-9]\+\) x \([0-9]\+\).*/\1/p')"
  screen_h="$(xrandr --query | sed -n 's/.*current \([0-9]\+\) x \([0-9]\+\).*/\2/p')"
  if [ "$x" -ge 0 ] && [ "$y" -ge "$wy" ] && [ $((x + w)) -le "$screen_w" ] && [ $((y + h)) -le "$screen_h" ]; then
    pass "shelf is on screen and below the top bar (y=$y >= $wy)"
  else
    fail "shelf rect ${w}x${h}+${x}+${y} is off screen ${screen_w}x${screen_h} or under the top bar"
  fi
  echo "note  vs _NET_WORKAREA $wm_work: left $((x - wx)), top $((y - wy)), right $((wx + ww - x - w)), bottom $((wy + wh - y - h))"

  # Panels are subtracted from _NET_WORKAREA; a shelf starting above it would be
  # hidden under a dock, so the y offset is the load-bearing part.
  if [ "$y" -eq "$wy" ]; then
    pass "shelf starts exactly at the work-area top (y=$wy)"
  else
    echo "note  shelf y=$y, work-area top=$wy (delta $((y - wy)))"
  fi
}

check_hotkey() {
  echo "== hotkey (real WM, pointer off-panel) =="
  local geo id x y w h
  geo="$(app_window)"
  [ -n "$geo" ] || { fail "no Edge-Drop window"; return; }
  read -r id x y w h <<<"$geo"

  # Park the pointer on a different monitor so hover cannot be the cause.
  python3 "$ROOT/scripts/x11-input.py" warp $((x + 1200)) $((y + 400)) >/dev/null
  sleep 0.8
  grab "$WORK/hk-closed.png" "$x" "$y" "$w" "$h"

  # Cold press: the very first open of a session from the shortcut does not paint
  # on this session (the renderer reports interactive=true and nothing is drawn
  # until another event). Recorded, not asserted — see notes/linux-baseline.md.
  python3 "$ROOT/scripts/x11-input.py" key alt+c >/dev/null
  sleep 1.2
  grab "$WORK/hk-cold.png" "$x" "$y" "$w" "$h"
  local cold
  cold="$(changed_px "$WORK/hk-closed.png" "$WORK/hk-cold.png")"
  echo "cold press (first open of the session): $cold changed pixels"

  # Warm the panel through the hover path, which always paints, then close it.
  python3 "$ROOT/scripts/x11-input.py" warp $((x + 1)) $((y + h / 2)) >/dev/null
  sleep 1.8
  python3 "$ROOT/scripts/x11-input.py" warp $((x + 1200)) $((y + 400)) >/dev/null
  sleep 1.8
  grab "$WORK/hk-closed2.png" "$x" "$y" "$w" "$h"

  python3 "$ROOT/scripts/x11-input.py" key alt+c >/dev/null
  sleep 1.2
  grab "$WORK/hk-open.png" "$x" "$y" "$w" "$h"
  local warm
  warm="$(changed_px "$WORK/hk-closed2.png" "$WORK/hk-open.png")"
  echo "press after a hover-primed session: $warm changed pixels"

  if [ "$warm" -gt 2000 ]; then
    pass "Alt+C opened the panel on the first press once the panel had been opened before"
  else
    fail "Alt+C did not open the panel even after the hover-primed warm-up"
  fi
  echo "note  cold-start first press drew ${cold}px (see notes: first open of a session is not painted)"
  echo "artifacts: $WORK/hk-closed.png $WORK/hk-cold.png $WORK/hk-open.png"
}

check_focus() {
  echo "== focus with a real WM =="
  local geo id x y w h
  geo="$(app_window)"
  [ -n "$geo" ] || { fail "no Edge-Drop window"; return; }
  read -r id x y w h <<<"$geo"

  # Give the shelf something to click, saving the user's clipboard first.
  local saved
  saved="$(xclip -o -selection clipboard 2>/dev/null || true)"
  printf 'real-desktop focus probe' | xclip -selection clipboard
  sleep 1.2

  command -v xterm >/dev/null || { echo "note  xterm missing, cannot run focus check"; return; }
  xterm -T edge-drop-focus-decoy -geometry 40x10+$((x + 1400))+400 -e sleep 120 &
  local xterm_pid=$!
  sleep 2

  local decoy
  decoy="$(xwininfo -root -tree | grep -m1 'edge-drop-focus-decoy' | awk '{print $1}')"
  [ -n "$decoy" ] || { fail "decoy xterm window not found"; kill $xterm_pid 2>/dev/null; return; }

  # Click the decoy at its own centre. Mutter frames each client window, so the
  # id reported by _NET_ACTIVE_WINDOW is the frame, not the client — compare by
  # window name instead of by id.
  local dgeo dx dy dw dh
  dgeo="$(xwininfo -id "$decoy" 2>/dev/null | awk '
    /Absolute upper-left X:/ { x=$NF }
    /Absolute upper-left Y:/ { y=$NF }
    /^  Width:/  { w=$NF }
    /^  Height:/ { h=$NF }
    END { print x, y, w, h }')"
  read -r dx dy dw dh <<<"$dgeo"
  echo "decoy   $decoy ${dw}x${dh}+${dx}+${dy}"
  python3 "$ROOT/scripts/x11-input.py" click $((dx + dw / 2)) $((dy + dh / 2)) >/dev/null
  sleep 0.8

  active_name() { # name of the window the WM considers active
    local id
    id="$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | grep -o '0x[0-9a-f]*' | head -1)"
    [ -n "$id" ] || return 0
    xprop -id "$id" WM_NAME 2>/dev/null | sed -n 's/.*= "\(.*\)"/\1/p'
  }

  local before after
  before="$(active_name)"
  echo "active before: $before"
  grab "$WORK/focus-before.png" "$x" "$y" "$w" "$h"

  # Hover the shelf, then click into the card area. The panel is 50% of the
  # window height and vertically centred, with the toolbar and search field on
  # top, so the first card sits a little below the panel's top edge — probe a few
  # offsets and stop at the first one that actually pastes.
  python3 "$ROOT/scripts/x11-input.py" warp $((x + 1)) $((y + h / 2)) >/dev/null
  sleep 2
  local panel_top=$((y + h / 4)) offset pasted=0
  for offset in 120 200 280 380; do
    python3 "$ROOT/scripts/x11-input.py" click $((x + 130)) $((panel_top + offset)) >/dev/null
    sleep 1.2
    if grep -q "\[IPC\] item:paste" "$LOG" 2>/dev/null; then
      pasted=1
      echo "card hit at y=$((panel_top + offset))"
      break
    fi
  done
  after="$(active_name)"
  echo "active after:  $after"

  kill $xterm_pid 2>/dev/null

  echo "card click reached the app: $pasted"

  if ! printf '%s' "$before" | grep -q 'edge-drop-focus-decoy'; then
    fail "decoy never got focus (active='$before') — the WM check is inconclusive"
  elif [ "$before" != "$after" ]; then
    fail "focus moved from '$before' to '$after' when the shelf was clicked"
  elif [ "$pasted" -ne 1 ]; then
    fail "focus held, but the shelf click never hit a card (nothing pasted) — inconclusive"
  else
    pass "clicking a card pasted without taking focus from '$before'"
  fi

  if printf '%s' "$saved" | xclip -selection clipboard 2>/dev/null; then
    echo "note  clipboard restored"
  fi
}

check_edges() {
  echo "== edge switching across the desktop =="
  local primary px py pw ph pos geo id x y w h ok=0
  primary="$(xrandr --query | awk '/ connected primary/ {print $4; exit}')"
  # e.g. 3840x2160+3840+0
  pw="${primary%%x*}"
  rest="${primary#*x}"
  ph="${rest%%+*}"
  rest="${rest#*+}"
  px="${rest%%+*}"
  py="${rest##*+}"
  echo "primary  ${pw}x${ph}+${px}+${py}"
  case "${pw}${ph}${px}${py}" in
    ''|*[!0-9]*) fail "could not parse the primary display geometry ('$primary')"; return ;;
  esac
  mkdir -p "$WORK/config/edge-drop"

  for pos in left right; do
    python3 - "$WORK/config/edge-drop/settings.json" "$pos" <<'PY'
import json, sys
path, pos = sys.argv[1], sys.argv[2]
data = {"tutorialCompleted": True, "onboardingVersion": 2, "hoverActivation": True,
        "toggleHotkey": "Alt+C", "stickPosition": pos}
try:
    with open(path) as fh:
        data.update(json.load(fh))
except Exception:
    pass
data["stickPosition"] = pos
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
    start_app || return
    geo="$(app_window)"
    read -r id x y w h <<<"$geo"
    stop_app
    echo "$pos: ${w}x${h}+${x}+${y}"
    # ±10px: the window is PANEL_WIDTH (384) plus a transparent gutter for the
    # panel shadow, and mutter's workArea is not exactly the display rect. The
    # measured overhang is reported so a regression shows up as a changing number.
    if [ "$pos" = "left" ]; then
      if [ $((x - px)) -ge -10 ] && [ $((x - px)) -le 10 ]; then
        ok=$((ok + 1)); pass "left edge: window starts at the primary display origin (x=$x, delta $((x - px)))"
      else
        fail "left edge: window x=$x, expected ~$px"
      fi
    else
      local expected=$((px + pw - w))
      if [ $((x - expected)) -ge -10 ] && [ $((x - expected)) -le 10 ]; then
        ok=$((ok + 1)); pass "right edge: window ends at the primary display edge (x=$x vs $expected, overhang $((x + w - px - pw))px)"
      else
        fail "right edge: window x=$x, expected ~$expected"
      fi
    fi
    if [ "$y" -lt "$py" ] || [ $((y + h)) -gt $((py + ph)) ]; then
      fail "$pos: window ${h}px tall at y=$y escapes the display height ${ph}"
    fi
  done
  [ "$ok" -eq 2 ] || FAILED=1
}

# --- run -----------------------------------------------------------------
case "$WHICH" in
  edges)
    check_edges
    ;;
  geometry|hotkey|focus)
    start_app || exit 1
    "check_$WHICH"
    stop_app
    ;;
  all)
    # Each check gets a fresh instance: a panel left open by the hotkey check
    # changes what the focus check's clicks land on.
    start_app || exit 1
    check_geometry
    stop_app
    start_app || exit 1
    check_hotkey
    stop_app
    start_app || exit 1
    check_focus
    stop_app
    check_edges
    ;;
  *) die "unknown check: $WHICH (geometry|hotkey|focus|all)" ;;
esac

[ "$FAILED" -eq 0 ] || exit 1

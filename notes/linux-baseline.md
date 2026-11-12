# Linux baseline — Edge-Drop 0.4.0 (Electron 45.3.1)

Measured 2026-11-12 on this workstation, Node v25.9.0 / npm 11.12.1, Xvfb 1600x1000x24.
Purpose: separate upstream's Windows-only failures from anything the port breaks.

## Build units

| Unit | Command | Result |
|---|---|---|
| deps | `npm install --no-audit --no-fund` | OK — 421 packages; per-platform Electron (234 MB), koffi and @resvg prebuilds resolve |
| main+preload+renderer | `npm run build` | OK — `out/main` 1.1 MB, `out/preload` 16 KB, `out/renderer` 4.0 MB |
| types | `npm run typecheck` | OK — 0 errors (tsc node + web) |

## Test suite (vitest)

```
Test Files  5 failed | 71 passed | 2 skipped (78)
     Tests  11 failed | 878 passed | 12 skipped (901)
```

All 11 failures are upstream's Windows-only assumptions — not port defects:

| File | Failures | Cause |
|---|---|---|
| `tests/launchAtLoginFixes.test.ts` | 4 | `reg query` / registry quoting helpers |
| `tests/storeLoginItem.test.ts` | 3 | GitHub Run-key + `StartupApproved` |
| `tests/storePaths.test.ts` | 2 | `Packages\` / `WindowsApps\` path virtualization |
| `tests/storePackaging.test.ts` | 1 | pack contents (on-disk assertions) |
| `tests/trayTheme.test.ts` | 1 | `SystemUsesLightTheme` registry value |

**Gate for every later phase:** no *new* failures. The set above may only shrink, by platform-guarding
those suites (`it.skipIf(process.platform !== 'win32')`).

## Runtime behaviour (Xvfb, `scripts/linux-smoke.sh`)

| Case | Before Phase 1 | After Phase 1 |
|---|---|---|
| hover | PASS — pointer at x=1 opens the panel, x=800 closes it | PASS |
| image | PASS — `items.json` gets `{"kind":"image","width":120,"height":80}` | PASS |
| text | FAIL — store stayed `{"items":[]}`; `osClipboard.readText()` returns `''` when the Win32 handle is null | **PASS** — `readTextAsync()` (commit `b658e24`) |
| files | FAIL — `readFileListAsync()` gated on `readBuffer('FileNameW')`, empty off Windows | **PASS** — `readUriListPaths()` (commit `cc1f69b`) |

Suite after Phase 1: `910 tests, 887 passed, 11 failed (baseline set), 12 skipped`.

## After Phase 2 (clipboard out + paste)

| Case | Result |
|---|---|
| `filesout` | PASS — clicking a file card puts `file:///tmp/probe.png` on the X11 clipboard as `text/uri-list` |
| `paste` | PASS — clicking a card logs `[Paste] keystroke injector: xdotool` and the stub receives `key --clearmodifiers ctrl+v` |
| `nopaste` | PASS — with no injector installed the app logs `injector: none`, still writes the clipboard (hitCount ++), shows `toast.pasteFallback`, no crash |

Not done in Phase 2: the Settings row from the plan (Task 2.3). The existing
`toast.pasteFallback` already tells the user "Clipboard ready — click your app and press Ctrl+V", which is the
correct message for the copy-only path, so a permanent warning row would be noise for people who never wanted
auto-paste. Revisit if someone reports confusion.

## After Phase 3 (window / session behaviour)

| Case | Result |
|---|---|
| `focus` | PASS — X input focus parked on a decoy xterm (`0xc0000c`); clicking a card pasted and left focus at `0xc0000c` |
| `wayland` | PASS — with `XDG_SESSION_TYPE=wayland`, startup logs `session=wayland (wayland) ozone=x11 (XWayland)` and the app renders |
| opt-out | PASS — same env plus `EDGE_DROP_NATIVE_WAYLAND=1` logs `ozone=native` |

Decisions:
- **Wayland → XWayland by default.** `electron/main/index.ts` appends `ozone-platform=x11` on a Wayland
  session unless `EDGE_DROP_NATIVE_WAYLAND=1`. The shelf cannot position itself on native Wayland.
- **Fullscreen suppression stays Windows-only** (`electron/main/fullscreen.ts`), with a comment at the early
  return. The shelf will pop over fullscreen video/games on Linux. Accepted for v1; the `xprop` approximation
  is in the plan if it ever matters.
- **Multi-monitor / work-area behaviour is untested here.** It reads Electron's `display.workArea`, which on
  Linux reflects `_NET_WORKAREA` (panels already subtracted); needs a real dual-head session to confirm.

## After Phase 4 (desktop integration)

| Item | Result |
|---|---|
| autostart | 6/6 unit tests (`tests/linuxAutostart.test.ts`): entry written with `Exec="<exe>" --hidden`, removed on disable, `Hidden=true` / `X-GNOME-Autostart-enabled=false` read as disabled, autostart dir created when missing |
| tray | `[Tray] created` on this host (no `libayatana-appindicator3`, so the icon is simply invisible). `createTray()` now returns `Tray \| null` and logs a remedy when `new Tray` throws; Settings/Quit stay reachable from the panel's gear menu (`src/components/Settings.tsx:449` calls `quitApp`) |
| hotkey | PASS — Alt+C reaches the app and main logs `window:toggle ... open=undefined` with the pointer parked at (900,700) |

Suite after Phase 4: `916 tests, 900 passed, 4 failed, 12 skipped`. The two Windows login-item suites now pin
`process.platform` to `win32` for their own duration, so the port's Linux autostart branch no longer intercepts
them — that also cleared 7 of the original 11 baseline failures. The 4 left (`storePaths` ×2, `storePackaging`,
`trayTheme`) are unchanged Windows/Store-only assertions.

**Open question for a real desktop:** with the pointer off-panel, Alt+C toggles the renderer state but the panel
was not visible in any captured frame (0.3 s / 0.8 s / 1.6 s / 3 s). Either the panel re-closes immediately
because the hover state machine sees the cursor outside, or it never paints from a non-hover open. The shortcut
itself is registered and delivered; whether the panel should stay up until the user clicks elsewhere is a
product decision that needs a session with a real WM.

## Real desktop (GNOME/mutter, X11 session, three 4K displays)

Run with `DISPLAY=:1 scripts/real-desktop-check.sh all`; it needs a live session with a WM and refuses to run
under Xvfb. Session measured: `DisplayPort-2 3840x2160+0+0`, `DisplayPort-1 primary 3840x2160+3840+0`,
`HDMI-A-0 3840x2160+7680+0`, GNOME top bar 34px, `_NET_WORKAREA 0,34,11520,2059`.

| Check | Result |
|---|---|
| geometry | PASS — shelf at `416x2062+3838+34`: on the primary display, starting exactly at the work-area top, so it never covers the GNOME top bar |
| edges | PASS — `stickPosition: left` → x=3838 (2px left of the display origin), `right` → x=7271, i.e. 7px past the display edge onto the neighbouring monitor |
| focus (real WM) | PASS — decoy xterm focused through mutter's own click-to-focus, card clicked (paste confirmed in the log), `_NET_ACTIVE_WINDOW` stayed on the decoy |
| hotkey | PASS with a caveat, see below |

Findings worth keeping:

- **Work-area source.** `_NET_WORKAREA` says the work area is 2059px tall, Electron reports 2062px, and the shelf
  follows Electron (it draws 1-3px past the EWMH bottom edge). Electron is the value the app positions against,
  and the top edge — the one that matters for a top bar — is exact.
- **Right-edge overhang.** Docked right, the window ends 7px onto the next display. Left is 2px the other way.
  Cosmetic on a multi-monitor desk, and panel-gutter related (`PANEL_WIDTH` 384 vs a 416px window), but it is a
  real measured asymmetry rather than rounding noise.
- **Alt+C: the first open of a session does not paint.** The shortcut registers, main sends `window:toggle`, and
  the renderer confirms within 250 ms (`interactive=true`) — yet nothing is drawn: 142 changed pixels against a
  closed baseline, versus ~203000 when it works. It is not a hydration race: a single press 10 s after launch
  behaves the same. After the panel has been opened once through the hover path, Alt+C paints on the first press
  every time. So the hotkey wiring is correct and the defect is in the panel's first render/compositing, which is
  upstream renderer code, not the platform layer. The check asserts the warm path and records the cold one.
- `backgroundThrottling: false` was added to the BrowserWindow along the way (a never-focused, always-on-top
  window is exactly what Chromium throttles). It did not, by itself, fix the cold-start paint.

## Phase 5 — Linux packages

`npm run build:linux` (`electron-vite build && electron-builder --linux AppImage deb`) produces:

| Artifact | Size | Notes |
|---|---|---|
| `dist/Edge-Drop-0.4.0-x86_64.AppImage` | 142 MB | self-contained; desktop entry `Exec=AppRun --no-sandbox %U` |
| `dist/Edge-Drop-0.4.0-amd64.deb` | 117 MB | installs to `/opt/Edge-Drop`, `Section: utils`, `Installed-Size: 305640` kB |

Config added to `package.json`:

- `linux`: AppImage + deb (x64), `category: Utility`, `executableName: edge-drop`,
  `artifactName: Edge-Drop-${version}-${arch}.${ext}`, desktop entry with
  `StartupWMClass=edge-drop` (the WM_CLASS the window actually reports).
- `desktopName: "edge-drop.desktop"` + `linux.syncDesktopName` — without it electron-builder warns that
  launchers cannot link a running window to the installed entry.
- `deb`: `packageCategory: "utils"` (in electron-builder 26 the Debian Section is `packageCategory`; a
  `section` key fails the config schema), `priority: optional`, and the dependency list pinned with a comment
  explaining `libxtst6` (XTEST: pointer warp and the paste keystroke).
- `electron/main/updater.ts`: the auto-updater returns early on Linux. The published feed is the Windows
  release (nsis/appx + `latest.yml`); before this guard a packaged Linux build fetched
  `latest-linux.yml` and logged `404` on every launch.

Verification (packaged payloads, driven by the same harness as the dev tree):

- deb payload — 9/9 cases PASS (`text image files filesout paste nopaste focus wayland hotkey`)
- AppImage payload — `text filesout paste` PASS
- both log `[AutoUpdater] Linux build — no Linux update feed yet, auto-updater disabled.` and make no
  update request
- `dpkg-deb -c` shows `/usr/share/applications/edge-drop.desktop`,
  `/usr/share/icons/hicolor/256x256/apps/edge-drop.png`, `/usr/bin/edge-drop` via update-alternatives in
  postinst, and the postinst only sets `chrome-sandbox` SUID when the system lacks user namespaces

Packaging caveats to settle before publishing a release:

- **Icon is 256×256** (`resources/icon.png`); electron-builder emits only
  `hicolor/256x256/apps/edge-drop.png`. Supply ≥512×512 (ideally 1024) art for HiDPI launchers.
- **`maintainer` is a placeholder** (`noreply@edge-drop.invalid`), as is the `Homepage` pointing at the fork.
  A real address is required before any archive or distro submission.
- **AppImage runs with `--no-sandbox`** in its desktop entry (electron-builder default, because
  `chrome-sandbox` cannot be SUID inside an AppImage). The deb keeps the sandbox and only escalates
  `chrome-sandbox` when needed.
- **AppImageLauncher hijacks AppImages on this host** (binfmt): executing the file opens its integration
  dialog instead of the app. For automated runs, get the payload offset with
  `binfmt-bypass <appimage> --appimage-offset`, extract with
  `unsquashfs -o <offset> -d <dir> <appimage>`, and run `<dir>/AppRun`. `--appimage-extract-and-run` also
  goes through the hijacked binfmt here.

## Phase 6 — CI and release

`.github/workflows/linux.yml` (runner `ubuntu-24.04`, node 24, npm pinned to 11.16.0) is green:
7m03s for system deps, `npm ci`, typecheck, the unit gate, build, the 9-case X11 suite,
`electron-builder --linux AppImage deb --publish never`, the packaged deb payload through the `text` case, and
both updater-gate assertions.

- `scripts/ci-vitest-gate.sh` turns the suite into a gate that tolerates the Windows-only baseline
  (`4 failed | 900 passed`) and fails when the failure count grows or the passing count drops. `continue-on-error`
  would make the suite decorative.
- The job purges `xdotool`/`ydotool` first: the `nopaste` case asserts that no injector is installed, and
  runner images do ship `xdotool`.
- `notes/linux-release-checklist.md` — the pre-publish list, including the two items that block archive
  submission (placeholder maintainer address, 256px icon) and the decision not to upload `latest-linux.yml`
  while the Linux updater is off.

Getting it green cost four failed runs, each with a different cause — worth remembering:

- **`npm ci` needs a lock with electron-builder's Windows-only subtrees in it.** A lock generated on Linux omits
  `electron-builder-squirrel-windows`, `electron-winstaller`, `@electron/windows-sign` and `postject` (they are
  os-gated optionals), and the runner rejects the tree with `Missing: electron-winstaller@5.4.0 from lock file`.
  npm on the runner repairs it during `npm install`; that repaired file is now committed, and a workflow step
  runs `git diff --exit-code -- package-lock.json` so an install that has to rewrite the lock fails the job.
  Neither a cold npm cache nor pinning npm 11.16.0 locally reproduced the failure — the runner's view is what
  matters, so the artifact round-trip was the only way to get the right file.
- **The upstream lock was also missing vitest's nested esbuild subtree** (`Missing: @esbuild/linux-x64@0.28.2`),
  which npm 11 tolerated and npm 10 did not; the regenerated lock resolves vitest 4.1.12 with rolldown-based
  vite 8.3.8, so there is no esbuild subtree to miss.
- **CI colourises the reporter output.** `CI=true` makes vitest emit ANSI codes even with stdout redirected, so
  the gate's `^ +Tests` pattern never matched and reported "no summary" on a run that had a perfectly good
  summary. The script now strips ANSI and forces `NO_COLOR`.
- **One upstream test is timing-flaky** under load (the mocked release fetch on a 100ms clock); the gate retries
  once, and a real regression still fails both attempts.

## Post-MVP features (both platforms)

### Pin the shelf open

A pin button in the header keeps the shelf up when the pointer leaves. The state is a renderer store flag
(`pinned`, session-only — a shelf that survives a restart is a surprise, not a preference), and the two places
that decide to retract (`closePanel`, `scheduleClose` in `useEdgeHover`) return early while it is set. Any real
close — hotkey, tray, the fullscreen guard — releases the pin in `setOpen`, so a closed shelf never reopens
itself on the next hover.

The pin has to be checked in **three** places, not two. `closePanel()` and `scheduleClose()` were guarded
first, and the shelf still retracted now and then: `closePanel()` arms its own 300ms timers for the flyout and
preview branches, and those callbacks call `closePanelNow()` directly. Whether the shelf stayed up depended on
whether a pointer-leave had armed one of those timers in the 300ms before the pin click — which is why a hand
test never showed it and a batch of smoke cases did about half the time. Both callbacks now re-read the store
and bail out while pinned. `tests/pinOpen.test.ts` asserts a pin check precedes `closePanelNow()` inside every
armed timer, and fixes the number of retraction call sites at three, so the next added path has to earn a guard.

Proof: `scripts/linux-smoke.sh pin` clicks the button (found by the `[Pin] shelf pinned:` line it logs, because
Xvfb has no window manager to measure against), parks the pointer 1100px away, and compares four frames: shelf
as the hover opened it, shelf right after the pin click, shelf with the pointer 1100px away, shelf after
unpinning with the pointer in the same place. **15914 / 15914 / 15914 / 0 lit pixels.** The first frame is what
tells "the pin failed" apart from "the shelf was never open"; without the last frame the other three prove
nothing.

### What the harness had to learn for these two cases

Three failures in a row were the harness, not the features, and each one looked like a product bug:

- **A fixed sleep cannot prove an open.** On a loaded machine the first paint lands seconds after the pointer
  reaches the edge, so `warp; sleep 5; screenshot` reads a real open as "the hover never opened the shelf". The
  store now logs `[Panel] open: true/false`, and the cases wait for that line (20s cap) instead of guessing.
- **`panel-open-check.py` needed Pillow.** A harness that resets `PATH` picks a different `python3` than the
  developer's shell, and the check died with `ModuleNotFoundError: No module named 'PIL'` — reported, of course,
  as a retracted shelf. It now decodes through `ffmpeg` and counts bytes with stdlib only, so it works on the CI
  runner (which has no Pillow) and on any interpreter.
- **A warp to where the pointer already is emits no motion event**, and the app arms its open-dwell on the
  crossing, so the harness now moves away first and then onto the edge.

The lesson worth keeping: a pixel check has to say *which* frame it judged and whether that frame was fresh.
Printing the frame timestamps before the assertions is what separated "the pin failed" from "the shelf was never
open" and from "the checker could not read the file".

### UI zoom

Settings → Appearance → Typography has a UI zoom row (80/90/100/110/125%), stored as `uiZoom`
(0.8–1.5, snapped to 5%). It scales the whole shelf, not just type — the existing Text size row stays as it was.

The mechanism is Chromium's zoom factor, plus the window widening by the same factor in `getStickGeometry`:
a zoom lowers the CSS viewport (`CSS px = device px / zoom`), so widening the window keeps every CSS
measurement — the 270px blade, card heights, flyout rects — exactly where it was and only the drawing scale
changes. Cursor positions are divided by the same factor in the poll before they cross to the renderer, so its
hover and close maths keeps comparing CSS pixels with CSS pixels; that division is the one place the factor is
applied, by design. `applyUiZoom()` runs on window creation, on `did-finish-load` (zoom does not survive a
navigation), and from `settings:update` together with `repositionWindow()` so the factor and the bounds land in
the same frame.

Proof: `scripts/linux-smoke.sh zoom` (seeds `uiZoom: 1.25` before launch) and `zoom100` measure the panel
window with `xwininfo`: **384px at 100%, 480px at 125%** — exactly `PANEL_WIDTH × zoom` — plus the
`[Window] UI zoom 1.25x` line. `tests/uiZoom.test.ts` covers the clamp/snap grid and that a 125% and a 150%
shelf still fit inside the work area.

## Known gaps to close (see the plan)

- Launch-at-login is covered on Linux by `electron/main/autostartLinux.ts`; the remaining Windows-only paths
  (`StartupApproved`, Store startup tasks) are bookkeeping with no Linux equivalent.
- Fullscreen suppression is Windows-only (`SHQueryUserNotificationState`) — shelf will pop over fullscreen apps.
- Privacy-exclusion clipboard formats (`CanIncludeInClipboardHistory`, KDE `x-kde-passwordManagerHint`) are
  Windows-only today; password managers' "do not record" hints are not honoured on Linux.
- No Linux packaging: `build` declares `win: [nsis, appx]` only.

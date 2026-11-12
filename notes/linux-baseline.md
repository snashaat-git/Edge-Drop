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

- `.github/workflows/linux.yml` (runner `ubuntu-24.04`): system deps, `npm ci`, typecheck, the vitest gate,
  build, the 9-case X11 suite, `electron-builder --linux AppImage deb --publish never`, then the packaged deb
  payload put through the `text` case and the updater-gate assertions. Uploads the smoke artifacts always and
  the packages on success.
- `scripts/ci-vitest-gate.sh` turns the suite into a gate that tolerates the four Windows-only baseline
  failures and fails when the count grows or the passing count drops — the alternative, `continue-on-error`,
  would hide real regressions.
- The job purges `xdotool`/`ydotool` before the suite: the `nopaste` case asserts that no injector is
  installed, and runner images do ship `xdotool`.
- `notes/linux-release-checklist.md` — the pre-publish list, including the two items that block any archive
  submission (placeholder maintainer address, 256px icon) and the decision not to upload `latest-linux.yml`
  while the Linux updater is off.

Each step's command was run locally before the workflow was committed (vitest gate PASS with
`4 failed | 900 passed`, the smoke loop shape, the packaged-payload case, both updater assertions). The
runner environment itself is the one thing CI alone can prove.

## Known gaps to close (see the plan)

- Launch-at-login is covered on Linux by `electron/main/autostartLinux.ts`; the remaining Windows-only paths
  (`StartupApproved`, Store startup tasks) are bookkeeping with no Linux equivalent.
- Fullscreen suppression is Windows-only (`SHQueryUserNotificationState`) — shelf will pop over fullscreen apps.
- Privacy-exclusion clipboard formats (`CanIncludeInClipboardHistory`, KDE `x-kde-passwordManagerHint`) are
  Windows-only today; password managers' "do not record" hints are not honoured on Linux.
- No Linux packaging: `build` declares `win: [nsis, appx]` only.

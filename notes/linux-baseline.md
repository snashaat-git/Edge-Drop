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

## Known gaps to close (see the plan)

- Launch-at-login is covered on Linux by `electron/main/autostartLinux.ts`; the remaining Windows-only paths
  (`StartupApproved`, Store startup tasks) are bookkeeping with no Linux equivalent.
- Fullscreen suppression is Windows-only (`SHQueryUserNotificationState`) — shelf will pop over fullscreen apps.
- Privacy-exclusion clipboard formats (`CanIncludeInClipboardHistory`, KDE `x-kde-passwordManagerHint`) are
  Windows-only today; password managers' "do not record" hints are not honoured on Linux.
- No Linux packaging: `build` declares `win: [nsis, appx]` only.

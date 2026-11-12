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

| Case | State before the port |
|---|---|
| hover | PASS — pointer at x=1 opens the panel, x=800 closes it |
| image | PASS — `items.json` gets `{"kind":"image","width":120,"height":80}` |
| text | FAIL — store stays `{"items":[]}`; `osClipboard.readText()` returns `''` when the Win32 handle is null |
| files | FAIL — `readFileListAsync()` gates on `readBuffer('FileNameW')`, empty off Windows |

## Known gaps to close (see the plan)

- Paste gesture is a no-op: `simulatePaste()` body is entirely `if (process.platform === 'win32')`.
- Launch at login is a no-op: `app.setLoginItemSettings` is `@platform darwin,win32` (electron.d.ts:1951).
- Fullscreen suppression is Windows-only (`SHQueryUserNotificationState`) — shelf will pop over fullscreen apps.
- Privacy-exclusion clipboard formats (`CanIncludeInClipboardHistory`, KDE `x-kde-passwordManagerHint`) are
  Windows-only today; password managers' "do not record" hints are not honoured on Linux.
- No Linux packaging: `build` declares `win: [nsis, appx]` only.

# Linux release checklist

Run top to bottom before publishing a Linux build. Each item names the command or the
file that proves it; "it looked fine" is not a step.

## 1. Code gates

- [ ] `npm run typecheck` — exit 0
- [ ] `scripts/ci-vitest-gate.sh` — no regression against the Windows-only baseline
      (4 upstream failures: `storePaths` ×2, `storePackaging`, `trayTheme`)
- [ ] `npm run build` — exit 0

## 2. Session behaviour (needs a real desktop, not Xvfb)

- [ ] `DISPLAY=:N scripts/real-desktop-check.sh all` — geometry, edges, focus, hotkey all PASS
- [ ] On a Wayland session, confirm `[Main] linux session=wayland … ozone=x11 (XWayland)` in the log
      and that hover + click still work
- [ ] Second monitor: dock both left and right, shelf lands on the intended display
      (the right edge overhangs its display by ~7px as of 0.4.0 — accepted, see notes)
- [ ] Hotkey **cold start**: first Alt+C of a session paints nothing; a hover first fixes it.
      Upstream renderer bug, unfixed — decide per release whether to ship it

## 3. Package

- [ ] `npm run build:linux` (never call `electron-builder` directly: it packs whatever is in `out/`)
- [ ] `dist/*.deb` control fields: `Section: utils`, `Depends` includes `libxtst6`,
      `Maintainer` is a real address (currently `noreply@edge-drop.invalid` — must change)
- [ ] `dist/*.AppImage` desktop entry: `StartupWMClass=edge-drop`, `Exec=AppRun --no-sandbox %U`
- [ ] Icon art is ≥512px (currently 256px: only `hicolor/256x256` ships)

## 4. Artifact verification

- [ ] deb payload: `EDGE_DROP_BIN=<payload>/opt/Edge-Drop/edge-drop EDGE_DROP_BIN_ARGS=--no-sandbox \
      scripts/linux-smoke.sh <case>` for all 9 cases
- [ ] AppImage payload: at least `text filesout paste`
- [ ] Packaged log contains `[AutoUpdater] Linux build — no Linux update feed yet` and no
      `latest-linux.yml` request
- [ ] Install on a clean VM: `sudo dpkg -i dist/*.deb`, launch from the app grid (icon + name correct,
      no duplicate entry while running), Settings → Quit works with no tray host installed
- [ ] Launch at login writes `~/.config/autostart/edge-drop.desktop` with `--hidden`

## 5. Paste into a third-party app (unproven in CI)

- [ ] With `xdotool` installed: copy text, click a card while a text editor is focused — the text lands
      in the editor, the editor keeps focus
- [ ] With `ydotool` only (native Wayland): same check
- [ ] With neither: the card copies, shows `toast.pasteFallback`, no crash

## 6. Publish

- [ ] Tag `v<version>` and attach `dist/*.deb` + `dist/*.AppImage`
- [ ] Do **not** upload `latest-linux.yml` until a Linux update feed exists; the updater is disabled on
      Linux, so the file would only invite clients that cannot use it
- [ ] Release notes state: X11 verified, Wayland via XWayland only (native Wayland cannot position the
      shelf — `setBounds` is unsupported there), fullscreen suppression is Windows-only

## Known gaps shipped with 0.4.0

| Gap | Impact | Where |
|---|---|---|
| First hotkey open of a session does not paint | needs a second press or a hover first | upstream renderer |
| Right-edge dock overhangs ~7px onto the next display | cosmetic, multi-monitor only | `window.ts` positioning |
| Icon art is 256px | soft in HiDPI launchers | `resources/icon.png` |
| Tray icon needs a status-notifier host | GNOME: install `libayatana-appindicator3-1` + AppIndicator extension | `tray.ts` logs the remedy |
| No fullscreen/video suppression | shelf pops over fullscreen video and games | `fullscreen.ts` |
| `xdotool`/`ydotool` never exercised in CI | paste injection past the stub is unverified | `scripts/linux-smoke.sh` `paste` |

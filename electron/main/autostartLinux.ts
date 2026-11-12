/**
 * Launch at login on Linux.
 *
 * Electron does not implement this here: `app.setLoginItemSettings` is
 * `@platform darwin,win32` (node_modules/electron/electron.d.ts), so on Linux
 * the toggle in Settings wrote nothing and the app never came back after a
 * reboot. The XDG convention is a desktop entry in
 * `$XDG_CONFIG_HOME/autostart` (default `~/.config/autostart`), which every
 * desktop environment's session manager reads at login.
 *
 * The entry runs the packaged binary with `--hidden`, matching the Windows
 * behaviour: the shelf comes up without stealing attention.
 */
import { app } from 'electron'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

function autostartDir(): string {
  const base = process.env.XDG_CONFIG_HOME?.trim() || join(homedir(), '.config')
  return join(base, 'autostart')
}

/** Absolute path of the autostart entry this app owns. */
export function autostartEntryPath(): string {
  return join(autostartDir(), 'edge-drop.desktop')
}

/**
 * True when the entry exists and has not been switched off by the user or by
 * their desktop's own "startup applications" panel (both mark it `Hidden=true`
 * or `X-GNOME-Autostart-enabled=false` rather than deleting it).
 */
export function linuxAutostartEnabled(): boolean {
  try {
    const path = autostartEntryPath()
    if (!existsSync(path)) return false
    const body = readFileSync(path, 'utf8')
    if (/^Hidden=true$/m.test(body)) return false
    if (/^X-GNOME-Autostart-enabled=false$/m.test(body)) return false
    return true
  } catch {
    return false
  }
}

/** Write or remove the autostart entry. Returns false when the filesystem refused. */
export function setLinuxAutostart(enabled: boolean): boolean {
  try {
    const path = autostartEntryPath()
    if (!enabled) {
      if (existsSync(path)) rmSync(path)
      return true
    }
    mkdirSync(autostartDir(), { recursive: true })
    const exec = app.getPath('exe')
    const lines = [
      '[Desktop Entry]',
      'Type=Application',
      'Name=Edge-Drop',
      'Comment=Clipboard shelf on the edge of your screen',
      // Quoted: install paths on Linux routinely contain spaces.
      `Exec="${exec}" --hidden`,
      'Terminal=false',
      'X-GNOME-Autostart-enabled=true',
      'StartupNotify=false',
      ''
    ]
    writeFileSync(path, lines.join('\n'), { mode: 0o644 })
    return true
  } catch (err) {
    console.error('[LoginItems] linux autostart write failed:', err)
    return false
  }
}

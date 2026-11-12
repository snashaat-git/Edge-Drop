/**
 * Linux launch-at-login is an XDG autostart entry, not an Electron setting:
 * `app.setLoginItemSettings` is `@platform darwin,win32`, so before this module
 * the Settings toggle wrote nothing and the app never came back after a reboot.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

vi.mock('electron', () => ({
  // A path with a space, which is the case that breaks unquoted entries.
  app: { getPath: (name: string) => (name === 'exe' ? '/opt/Edge Drop/edge-drop' : '/tmp') }
}))

const { autostartEntryPath, linuxAutostartEnabled, setLinuxAutostart } = await import(
  '../electron/main/autostartLinux'
)

let home: string
let previousConfigHome: string | undefined

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'edge-drop-autostart-'))
  previousConfigHome = process.env.XDG_CONFIG_HOME
  process.env.XDG_CONFIG_HOME = home
})

afterEach(() => {
  if (previousConfigHome === undefined) delete process.env.XDG_CONFIG_HOME
  else process.env.XDG_CONFIG_HOME = previousConfigHome
  rmSync(home, { recursive: true, force: true })
})

describe('linux autostart entry', () => {
  it('reports disabled when no entry exists', () => {
    expect(linuxAutostartEnabled()).toBe(false)
  })

  it('writes a desktop entry that quotes the executable and passes --hidden', () => {
    expect(setLinuxAutostart(true)).toBe(true)
    const body = readFileSync(autostartEntryPath(), 'utf8')
    expect(body).toContain('[Desktop Entry]')
    expect(body).toContain('Type=Application')
    expect(body).toContain('Exec="/opt/Edge Drop/edge-drop" --hidden')
    expect(body).toContain('X-GNOME-Autostart-enabled=true')
    expect(linuxAutostartEnabled()).toBe(true)
  })

  it('removes the entry when disabled', () => {
    setLinuxAutostart(true)
    expect(existsSync(autostartEntryPath())).toBe(true)
    expect(setLinuxAutostart(false)).toBe(true)
    expect(existsSync(autostartEntryPath())).toBe(false)
    expect(linuxAutostartEnabled()).toBe(false)
  })

  it('creates the autostart directory when it does not exist yet', () => {
    expect(existsSync(join(home, 'autostart'))).toBe(false)
    expect(setLinuxAutostart(true)).toBe(true)
    expect(existsSync(autostartEntryPath())).toBe(true)
  })

  it('treats X-GNOME-Autostart-enabled=false as disabled (the desktop panel switched it off)', () => {
    setLinuxAutostart(true)
    const path = autostartEntryPath()
    writeFileSync(
      path,
      readFileSync(path, 'utf8').replace(
        'X-GNOME-Autostart-enabled=true',
        'X-GNOME-Autostart-enabled=false'
      )
    )
    expect(linuxAutostartEnabled()).toBe(false)
  })

  it('treats Hidden=true as disabled', () => {
    setLinuxAutostart(true)
    writeFileSync(autostartEntryPath(), '[Desktop Entry]\nType=Application\nHidden=true\n')
    expect(linuxAutostartEnabled()).toBe(false)
  })
})

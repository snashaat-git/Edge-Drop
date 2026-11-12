/**
 * Sending Ctrl/Cmd+V to whatever window is focused.
 *
 * Windows keeps its SendKeys path through the persistent PowerShell host (see
 * `simulatePaste` in ipc.ts). Everywhere else a small external tool is the only
 * honest option: Electron exposes no input-injection API and neither the
 * renderer nor the main process can synthesise a keystroke into another app.
 *
 *   Linux / X11                  xdotool key --clearmodifiers ctrl+v
 *   Linux / Wayland (XWayland)   ydotool key 29:1 47:1 47:0 29:0
 *   macOS                        osascript -e 'tell application "System Events" to keystroke "v" using command down'
 *
 * ydotool needs its daemon and works on native Wayland; xdotool is the common
 * install and works through XWayland, which is what the shelf runs under anyway.
 */
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { delimiter, join } from 'node:path'

export type PasteMethod = 'sendkeys' | 'xdotool' | 'ydotool' | 'osascript' | 'none'

let cached: PasteMethod | null = null

function onPath(bin: string): boolean {
  const dirs = (process.env.PATH ?? '').split(delimiter)
  return dirs.some((dir) => dir.length > 0 && existsSync(join(dir, bin)))
}

/** Which injector this machine has. Detected once; the answer cannot change mid-run. */
export function detectPasteMethod(): PasteMethod {
  if (cached) return cached
  if (process.platform === 'win32') cached = 'sendkeys'
  else if (process.platform === 'darwin') cached = onPath('osascript') ? 'osascript' : 'none'
  else if (onPath('xdotool')) cached = 'xdotool'
  else if (onPath('ydotool')) cached = 'ydotool'
  else cached = 'none'
  console.log(`[Paste] keystroke injector: ${cached}`)
  return cached
}

/**
 * Fire the paste keystroke. Returns false when nothing is installed, so the
 * caller can tell the user the clipboard is ready and a manual paste is needed.
 * Windows is not handled here — it returns false too, and ipc.ts uses its
 * PowerShell host instead.
 */
export function sendPasteKeystroke(onError?: (err: Error) => void): boolean {
  const done = (err: Error | null): void => {
    if (err) onError?.(err)
  }
  switch (detectPasteMethod()) {
    case 'xdotool':
      execFile('xdotool', ['key', '--clearmodifiers', 'ctrl+v'], done)
      return true
    case 'ydotool':
      execFile('ydotool', ['key', '29:1', '47:1', '47:0', '29:0'], done)
      return true
    case 'osascript':
      execFile(
        'osascript',
        ['-e', 'tell application "System Events" to keystroke "v" using command down'],
        done
      )
      return true
    default:
      return false
  }
}

/**
 * The non-Windows clipboard readers (Linux / macOS).
 *
 * These exist because Electron 44+ has no synchronous clipboard: the Win32
 * koffi shim that the watcher uses on Windows returns '' when the native
 * handle is null, so text and copied files have to come from Electron's async
 * ClipboardItem API instead. Keep this suite off Windows — there the sync
 * Win32 path is the one under test and these functions defer to it.
 */
import { describe, it, expect, vi, beforeEach, afterAll } from 'vitest'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const { readMock } = vi.hoisted(() => ({ readMock: vi.fn() }))

vi.mock('electron', () => ({
  clipboard: {
    read: (...args: unknown[]) => readMock(...args),
    write: vi.fn(),
    writeText: vi.fn(),
    clear: vi.fn()
  },
  ClipboardItem: class {
    data: Record<string, Blob>
    constructor(data: Record<string, Blob>) {
      this.data = data
    }
  },
  nativeImage: {
    createFromBuffer: () => ({ isEmpty: () => true }),
    createEmpty: () => ({ isEmpty: () => true })
  }
}))

const { readTextAsync, readUriListPaths } = await import('../electron/clipboard/osClipboard')

/** A ClipboardItem-shaped stub: only the members the readers touch. */
function clipItem(entries: Record<string, string>) {
  return {
    types: Object.keys(entries),
    getType: async (type: string) => new Blob([entries[type]], { type })
  }
}

const dir = mkdtempSync(join(tmpdir(), 'edge-drop-linux-'))
const spacedPath = join(dir, 'a b.png')
const plainPath = join(dir, 'plain.txt')
writeFileSync(spacedPath, 'x')
writeFileSync(plainPath, 'x')

afterAll(() => rmSync(dir, { recursive: true, force: true }))

beforeEach(() => {
  readMock.mockReset()
})

describe.skipIf(process.platform === 'win32')('readTextAsync', () => {
  it('returns the plain text carried by the clipboard', async () => {
    readMock.mockResolvedValue([clipItem({ 'text/plain': 'linux clipboard probe' })])
    await expect(readTextAsync()).resolves.toBe('linux clipboard probe')
  })

  it('returns an empty string when the clipboard has no text', async () => {
    readMock.mockResolvedValue([clipItem({ 'image/png': 'binary' })])
    await expect(readTextAsync()).resolves.toBe('')
  })

  it('returns an empty string when the clipboard is empty', async () => {
    readMock.mockResolvedValue([])
    await expect(readTextAsync()).resolves.toBe('')
  })

  it('returns an empty string when the platform clipboard read throws', async () => {
    readMock.mockRejectedValue(new Error('X connection broken'))
    await expect(readTextAsync()).resolves.toBe('')
  })
})

describe.skipIf(process.platform === 'win32')('readUriListPaths', () => {
  it('decodes percent-escaped file URIs to absolute paths', async () => {
    readMock.mockResolvedValue([
      clipItem({ 'text/uri-list': `file://${encodeURI(spacedPath)}\r\n` })
    ])
    await expect(readUriListPaths()).resolves.toEqual([spacedPath])
  })

  it('keeps every file of a multi-file copy', async () => {
    readMock.mockResolvedValue([
      clipItem({ 'text/uri-list': `file://${encodeURI(spacedPath)}\r\nfile://${encodeURI(plainPath)}\r\n` })
    ])
    await expect(readUriListPaths()).resolves.toEqual([spacedPath, plainPath])
  })

  it('ignores comments, http URLs and paths that no longer exist', async () => {
    readMock.mockResolvedValue([
      clipItem({
        'text/uri-list': [
          '# copied files',
          'https://example.com/a.png',
          `file://${encodeURI(plainPath)}`,
          `file://${dir}/gone.txt`
        ].join('\r\n')
      })
    ])
    await expect(readUriListPaths()).resolves.toEqual([plainPath])
  })

  it('returns null when the clipboard carries no uri list', async () => {
    readMock.mockResolvedValue([clipItem({ 'text/plain': 'just text' })])
    await expect(readUriListPaths()).resolves.toBeNull()
  })

  it('returns null when every entry was filtered out', async () => {
    readMock.mockResolvedValue([clipItem({ 'text/uri-list': 'https://example.com/x\r\n' })])
    await expect(readUriListPaths()).resolves.toBeNull()
  })
})

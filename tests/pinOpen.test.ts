import { beforeEach, describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { useStore } from '../src/store/appStore'

const read = (p: string) => readFileSync(join(__dirname, '..', p), 'utf8')
const hoverSrc = () => read('src/hooks/useEdgeHover.ts')

/**
 * A pinned shelf once retracted on its own, and only sometimes: `closePanel()`
 * arms a 300ms timer for the flyout and preview branches, and those callbacks
 * called `closePanelNow()` directly. Whether the shelf stayed up depended on
 * whether a pointer-leave had armed that timer just before the pin click.
 * These tests pin the guard to every retraction path, not just the two obvious
 * ones, because that is exactly the hole that made it intermittent.
 */
describe('pin — store contract', () => {
  beforeEach(() => {
    useStore.setState({ open: false, pinned: false })
  })

  it('starts unpinned', () => {
    expect(useStore.getState().pinned).toBe(false)
  })

  it('keeps the pin while the shelf is open', () => {
    useStore.getState().setOpen(true)
    useStore.getState().setPinned(true)
    expect(useStore.getState().pinned).toBe(true)
  })

  it('releases the pin when the shelf closes, so a reopen cannot resurrect it', () => {
    useStore.getState().setOpen(true)
    useStore.getState().setPinned(true)
    useStore.getState().setOpen(false)
    expect(useStore.getState().pinned).toBe(false)
  })

  it('does not clear the pin when the shelf is merely re-opened', () => {
    useStore.getState().setPinned(true)
    useStore.getState().setOpen(true)
    expect(useStore.getState().pinned).toBe(true)
  })
})

describe('pin — every retraction path is guarded', () => {
  it('guards the function that retracts and the function that schedules it', () => {
    expect(hoverSrc().match(/if \(state\.pinned\) return/g)?.length).toBe(2)
  })

  it('re-checks the pin inside the armed 300ms timers before calling closePanelNow', () => {
    const src = hoverSrc()
    // Split on each armed timer and keep the body up to its closing `}, 300)`.
    const bodies = src
      .split('graceTimer = window.setTimeout(')
      .slice(1)
      .map((chunk) => chunk.slice(0, chunk.indexOf('}, 300)')))

    const armedClosers = bodies.filter((body) => body.includes('closePanelNow()'))
    expect(armedClosers.length).toBe(2) // flyout branch + preview branch
    for (const body of armedClosers) {
      expect(body).toContain('pending.pinned')
      // The check must come before the retraction, not after it.
      expect(body.indexOf('pending.pinned')).toBeLessThan(body.indexOf('closePanelNow()'))
    }
  })

  it('keeps the number of retraction call sites at three', () => {
    const src = hoverSrc()
    // The definition is `const closePanelNow = () =>`, so this counts calls only:
    // flyout timer, preview timer, and the direct path at the end of closePanel.
    // A new call site is a new place that has to earn a pin check.
    expect(src.match(/closePanelNow\(\)/g)?.length ?? 0).toBe(3)
  })
})

describe('pin — the control and its evidence', () => {
  it('renders a pin button that reports its state and logs the toggle', () => {
    const src = read('src/components/Header.tsx')
    expect(src).toContain('aria-pressed={pinned}')
    expect(src).toContain('const next = !pinned')
    expect(src).toContain('setPinned(next)')
    // The harness has no selector for this button; the log line is what tells
    // "never clicked" apart from "clicked and not honoured".
    expect(src).toContain('[Pin] shelf pinned:')
  })

  it('sits in the header, so it is reachable while the shelf is open', () => {
    const src = read('src/components/Header.tsx')
    expect(src).toMatch(/!settingsOpen && \(/)
  })
})

describe('pin — strings in every language', () => {
  it('has both the pin and unpin label in all 31 locales', () => {
    const src = read('src/i18n/translations.ts')
    const dictionaries = src.match(/export const \w+: TranslationKeys = \{/g)?.length ?? 0
    expect(dictionaries).toBe(31)
    // A lookbehind, because `"unpin":` contains `"pin":` as a substring.
    const count = (key: string) =>
      src.match(new RegExp(`(?<![a-zA-Z])"${key}":`, 'g'))?.length ?? 0
    // Per locale: header.pin/unpin (ours) plus upstream's own pin/unpin pair for
    // pinning a clipboard item, which lives in its card group. header's copy is
    // the one that has to be translated everywhere, and it is counted alongside
    // the upstream keys rather than mistaken for a duplicate.
    expect(count('pin')).toBe(dictionaries * 3)
    expect(count('unpin')).toBe(dictionaries * 2)
  })
})

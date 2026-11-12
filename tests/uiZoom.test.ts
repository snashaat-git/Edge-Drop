import { describe, it, expect, beforeEach } from 'vitest'
import { normalizeUiZoom, DEFAULT_SETTINGS, UI_ZOOM_MAX, UI_ZOOM_MIN } from '../shared/types'
import { computeStickBounds, type DisplayInfo } from '../electron/main/geometry'
import { useStore } from '../src/store/appStore'

// UI zoom scales the whole shelf, not just the type: the renderer keeps laying
// out in CSS pixels while the window widens by the same factor, so these are the
// two seams worth pinning down — the stored number, and the geometry that has to
// follow it.

function makeDisplay(id: number, x: number, y: number, w: number, h: number): DisplayInfo {
  return { id, workArea: { x, y, width: w, height: h }, scaleFactor: 1, isPrimary: id === 1 }
}

const PRIMARY = makeDisplay(1, 0, 0, 1920, 1040)

/** What window.ts does before asking for bounds: CSS width times the factor. */
const zoomedWindowWidth = (zoom: number, panelWidth = 384) => Math.round(panelWidth * zoom)

describe('normalizeUiZoom', () => {
  it('defaults to 1 for anything that is not a number', () => {
    expect(normalizeUiZoom(undefined)).toBe(1)
    expect(normalizeUiZoom(null)).toBe(1)
    expect(normalizeUiZoom('1.25')).toBe(1)
    expect(normalizeUiZoom(Number.NaN)).toBe(1)
    expect(DEFAULT_SETTINGS.uiZoom).toBe(1)
  })

  it('clamps to the supported range instead of honouring a hand-edited file', () => {
    expect(normalizeUiZoom(0.1)).toBe(UI_ZOOM_MIN)
    expect(normalizeUiZoom(4)).toBe(UI_ZOOM_MAX)
    expect(normalizeUiZoom(0.8)).toBe(0.8)
    expect(normalizeUiZoom(1.5)).toBe(1.5)
  })

  it('snaps onto the 5% grid the settings pills use', () => {
    expect(normalizeUiZoom(1.234)).toBe(1.25)
    expect(normalizeUiZoom(1.11)).toBe(1.1)
    expect(normalizeUiZoom(0.876)).toBe(0.9)
    // Float noise must not survive the round trip to the settings file.
    expect(normalizeUiZoom(1.15)).toBe(1.15)
    expect(normalizeUiZoom(0.1 + 0.7)).toBe(0.8)
  })
})

describe('zoomed window geometry', () => {
  it('widens the window by the zoom factor, so the panel keeps its CSS width', () => {
    expect(zoomedWindowWidth(1.25)).toBe(480)
    expect(zoomedWindowWidth(0.8)).toBe(307)
    expect(zoomedWindowWidth(1.0)).toBe(384)
  })

  it('a 125% shelf still sits flush against the edge and inside the work area', () => {
    const width = zoomedWindowWidth(1.25)
    const left = computeStickBounds({ position: 'left', displays: [PRIMARY], windowWidth: width })
    expect(left.x).toBe(0)
    expect(left.width).toBe(width)
    expect(left.x + left.width).toBeLessThanOrEqual(PRIMARY.workArea.width)

    const right = computeStickBounds({ position: 'right', displays: [PRIMARY], windowWidth: width })
    expect(right.x + right.width).toBe(PRIMARY.workArea.width)
    expect(right.x).toBeGreaterThanOrEqual(0)
  })

  it('a 150% shelf on the narrowest pane still has room for its own panel', () => {
    const narrow = makeDisplay(1, 0, 0, 1280, 800)
    const width = zoomedWindowWidth(UI_ZOOM_MAX)
    const r = computeStickBounds({ position: 'right', displays: [narrow], windowWidth: width })
    expect(r.width).toBe(576)
    expect(r.x).toBe(1280 - 576)
  })
})

describe('pinning the shelf open', () => {
  beforeEach(() => {
    useStore.setState({ pinned: false, open: false })
  })

  it('starts unpinned, so a fresh window behaves like the shelf always has', () => {
    expect(useStore.getState().pinned).toBe(false)
  })

  it('survives the close attempt that a hover-out would make', () => {
    useStore.getState().setOpen(true)
    useStore.getState().setPinned(true)
    expect(useStore.getState().pinned).toBe(true)
    expect(useStore.getState().open).toBe(true)
  })

  it('is released by any real close, so it cannot reopen on the next hover', () => {
    useStore.getState().setOpen(true)
    useStore.getState().setPinned(true)
    useStore.getState().setOpen(false)
    expect(useStore.getState().pinned).toBe(false)
    expect(useStore.getState().open).toBe(false)
  })
})

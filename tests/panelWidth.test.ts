import { describe, it, expect } from 'vitest'
import { PANEL_WIDTH_MIN, resolvePanelWidthCss } from '../electron/main/geometry'
import { PANEL_WIDTH_RATIO_DEFAULT, PANEL_WIDTH_RATIO_MAX, PANEL_WIDTH_RATIO_MIN, normalizePanelWidthRatio } from '../shared/types'

/**
 * The shelf used to be a fixed 270 CSS px. It is now a share of the screen
 * (`panelWidthRatio`, a third by default), so these tests pin:
 *  - the share is of the *screen*, not of the zoomed viewport,
 *  - the blade never goes below the original design width,
 *  - a hand-edited settings file cannot ask for an unusable width.
 */

// This workstation's left monitor in Electron units (see the display dump in
// notes/linux-baseline.md): 3615 DIP wide at a 1.0625 scale factor.
const SCREEN_3615 = { width: 3615 }

describe('normalizePanelWidthRatio', () => {
  it('keeps a valid ratio', () => {
    expect(normalizePanelWidthRatio(1 / 3)).toBeCloseTo(0.333, 3)
    expect(normalizePanelWidthRatio(0.25)).toBe(0.25)
  })

  it('defaults a missing or non-numeric value to a third', () => {
    expect(normalizePanelWidthRatio(undefined)).toBeCloseTo(PANEL_WIDTH_RATIO_DEFAULT, 3)
    expect(normalizePanelWidthRatio('wide')).toBeCloseTo(PANEL_WIDTH_RATIO_DEFAULT, 3)
    expect(normalizePanelWidthRatio(Number.NaN)).toBeCloseTo(PANEL_WIDTH_RATIO_DEFAULT, 3)
  })

  it('clamps to the usable range', () => {
    expect(normalizePanelWidthRatio(0.01)).toBe(PANEL_WIDTH_RATIO_MIN)
    expect(normalizePanelWidthRatio(0.95)).toBe(PANEL_WIDTH_RATIO_MAX)
  })
})

describe('resolvePanelWidthCss — blade width as a share of the screen', () => {
  it('is a third of the screen by default', () => {
    // 3615 / 1.0625 = 3402.35 CSS px of screen -> a third is 1133
    expect(resolvePanelWidthCss(SCREEN_3615, 1.0625, undefined)).toBe(1133)
  })

  it('covers the same share of the SCREEN at any UI zoom', () => {
    const at100 = resolvePanelWidthCss(SCREEN_3615, 1, 1 / 3)
    const at125 = resolvePanelWidthCss(SCREEN_3615, 1.25, 1 / 3)
    // The window is laid out in CSS px that Chromium scales by the zoom, so the
    // CSS width shrinks as the zoom grows — the pixels on screen do not.
    expect(at100 * 1).toBeGreaterThan(at125 * 1.25)
    expect(Math.abs(at100 * 1 - at125 * 1.25)).toBeLessThanOrEqual(2)
    // and both stay a third of the 3615 DIP screen
    expect(Math.abs(at100 - Math.round(3615 / 3))).toBeLessThanOrEqual(2)
    expect(Math.abs(Math.round(at125 * 1.25) - Math.round(3615 / 3))).toBeLessThanOrEqual(2)
  })

  it('honours a wider or narrower share', () => {
    expect(resolvePanelWidthCss(SCREEN_3615, 1, 0.25)).toBe(Math.round(3615 * 0.25))
    expect(resolvePanelWidthCss(SCREEN_3615, 1, 0.5)).toBe(Math.round(3615 * 0.5))
  })

  it('never goes below the design width on a small screen', () => {
    // 800px screen at the smallest allowed share would be 160px
    expect(resolvePanelWidthCss({ width: 800 }, 1, PANEL_WIDTH_RATIO_MIN)).toBe(PANEL_WIDTH_MIN)
    expect(resolvePanelWidthCss({ width: 1600 }, 1, 1 / 3)).toBeGreaterThan(PANEL_WIDTH_MIN)
  })

  it('clamps a hand-edited ratio through the normaliser', () => {
    expect(resolvePanelWidthCss(SCREEN_3615, 1, 9)).toBe(Math.round(3615 * PANEL_WIDTH_RATIO_MAX))
  })
})

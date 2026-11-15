export type StickPosition = 'left' | 'right' | 'top'

export interface DisplayInfo {
  id: number
  workArea: { x: number; y: number; width: number; height: number }
  scaleFactor?: number
  /** True when this is the OS-designated primary display. */
  isPrimary?: boolean
}

export interface StickBoundsParams {
  position: StickPosition
  displays: DisplayInfo[]
  displayId?: number
  /**
   * Persisted workArea geometry from the previous session.
   * Used as Tier-2 fuzzy match when the OS re-assigns numeric IDs on reboot.
   */
  savedWorkArea?: { x: number; y: number; width: number; height: number }
  /** Persisted scale factor — secondary discriminator for identical-geometry monitors. */
  savedScaleFactor?: number
  windowWidth: number
  windowHeight?: number
  horizontalOffset?: number
  currentBounds?: { x: number; y: number }
  previewActive?: boolean
}

export interface StickBoundsResult {
  x: number
  y: number
  width: number
  height: number
  displayId: number
  /** The resolved display, exposed so callers can persist fresh geometry. */
  resolvedDisplay: DisplayInfo
}

/**
 * Tolerance (pixels) for workArea fuzzy-match.
 *
 * Windows sometimes shifts a display's workArea origin by a few pixels after
 * a DWM restart, a driver update, or the taskbar repositioning — so exact
 * equality would miss the right monitor. 8px is well within the margin of
 * error while still being strict enough to disambiguate normal multi-monitor
 * layouts (monitors are separated by at least their own width).
 */
const BOUNDS_TOLERANCE = 8

function boundsMatch(
  a: { x: number; y: number; width: number; height: number },
  b: { x: number; y: number; width: number; height: number }
): boolean {
  return (
    Math.abs(a.x - b.x) <= BOUNDS_TOLERANCE &&
    Math.abs(a.y - b.y) <= BOUNDS_TOLERANCE &&
    Math.abs(a.width - b.width) <= BOUNDS_TOLERANCE &&
    Math.abs(a.height - b.height) <= BOUNDS_TOLERANCE
  )
}

/**
 * Inputs that identify which display the user picked.
 *
 * Display identifiers are not guaranteed to be unique: on X11 Chromium derives
 * `Display.id` from the monitor's EDID, so identical panels (same model, no
 * serial advertised) report the SAME id. When that happens the id alone cannot
 * pick the monitor, and whichever entry the array happens to list first wins —
 * the reported bug "selecting a monitor in Settings does not move the shelf".
 * Every resolution path therefore disambiguates colliding ids with the
 * persisted workArea (the geometry of the entry the user actually clicked).
 */
export interface StickDisplayParams {
  displays: DisplayInfo[]
  displayId?: number
  /** Persisted workArea geometry of the chosen display (preferred discriminator). */
  savedWorkArea?: { x: number; y: number; width: number; height: number }
  /** Persisted scale factor — secondary discriminator for identical-geometry monitors. */
  savedScaleFactor?: number
  /** Current window origin; enables Tier-3 nearest-display matching. */
  currentBounds?: { x: number; y: number }
  /** Set false to forbid Tier-3 (deterministic callers such as the display list). */
  allowNearest?: boolean
}

/**
 * Narrow a candidate set down to one display.
 *
 * Order of discrimination: persisted workArea → scale factor → OS primary →
 * first candidate (deterministic array order). With a single candidate the
 * first two steps are skipped, which is why this is also safe for Tier-2.
 */
function pickAmongCandidates(
  candidates: DisplayInfo[],
  savedWorkArea?: { x: number; y: number; width: number; height: number },
  savedScaleFactor?: number
): DisplayInfo | undefined {
  if (candidates.length === 0) return undefined
  let list = candidates
  if (list.length > 1 && savedWorkArea) {
    const byArea = list.filter(d => boundsMatch(d.workArea, savedWorkArea))
    if (byArea.length) list = byArea
  }
  if (list.length > 1 && savedScaleFactor !== undefined) {
    const byScale = list.filter(d => d.scaleFactor === savedScaleFactor)
    if (byScale.length) list = byScale
  }
  if (list.length > 1) {
    // Identical twins (same geometry AND scale): geometry is exhausted as a
    // discriminator by definition, so anchor on the OS-designated primary -
    // deterministic across reboots, independent of array order.
    const primaryCandidate = list.find(d => d.isPrimary)
    if (primaryCandidate) list = [primaryCandidate]
  }
  return list[0]
}

/** Resolve which display the shelf belongs on. Never returns undefined when `displays` is non-empty. */
export function resolveStickDisplay(params: StickDisplayParams): DisplayInfo {
  const { displays, displayId, savedWorkArea, savedScaleFactor, currentBounds, allowNearest } = params

  let display: DisplayInfo | undefined

  // ── Tier 1: session-local numeric ID match (fast path within same session) ──
  // Duplicate ids are resolved by the persisted geometry, not by array order.
  if (displayId !== undefined) {
    display = pickAmongCandidates(displays.filter(d => d.id === displayId), savedWorkArea, savedScaleFactor)
  }

  // ── Tier 2: cross-reboot fuzzy workArea match ──────────────────────────────────
  // The OS re-assigns numeric display IDs on every Windows boot, so the saved ID
  // will never match after a restart.  Instead we match on the persisted workArea
  // geometry (within BOUNDS_TOLERANCE) and optionally the DPI scale factor as a
  // secondary discriminator when two monitors share the same resolution.
  if (!display && savedWorkArea) {
    display = pickAmongCandidates(displays.filter(d => boundsMatch(d.workArea, savedWorkArea)), savedWorkArea, savedScaleFactor)
    // If nothing matched the saved display is genuinely gone; fall through.
  }

  // ── Tier 3: nearest-by-current-window-position (session continuity, no saved data) ──
  if (!display && displayId === undefined && currentBounds && allowNearest !== false) {
    display = findNearestDisplay(displays, currentBounds)
  }

  // ── Tier 4: primary display fallback ──────────────────────────────────────────
  if (!display) {
    display = displays.find(d => d.isPrimary) ?? displays[0]
  }

  return display
}

export function computeStickBounds(params: StickBoundsParams): StickBoundsResult {
  const { position, displays, displayId, savedWorkArea, savedScaleFactor, windowWidth, currentBounds } = params

  const display = resolveStickDisplay({
    displays,
    displayId,
    savedWorkArea,
    savedScaleFactor,
    currentBounds,
    allowNearest: true
  })

  const wa = display.workArea

  let x: number
  let y: number
  let width: number
  let height: number

  switch (position) {
    case 'left':
      x = wa.x
      y = wa.y
      width = windowWidth
      height = wa.height
      break
    case 'right':
      x = wa.x + wa.width - windowWidth
      y = wa.y
      width = windowWidth
      height = wa.height
      break
    case 'top': {
      const dockWidth = Math.min(wa.width - 60, 1080)
      const previewHeight = Math.min(wa.height - 20, 720)
      const dockHeight = params.previewActive ? previewHeight : (params.windowHeight ?? 480)
      const hOffset = Math.min(1, Math.max(0, params.horizontalOffset ?? 0.5))
      const pad = wa.width >= dockWidth + 60 ? 30 : 0
      const minX = wa.x + pad
      const maxX = wa.x + wa.width - dockWidth - pad
      const dockX = minX + Math.round(Math.max(0, maxX - minX) * hOffset)
      // Allocate 30px transparent gutters on left and right for curved connector arcs (flares)
      x = dockX - 30
      y = wa.y
      width = dockWidth + 60
      height = dockHeight
      break
    }
  }

  return { x, y, width, height, displayId: display.id, resolvedDisplay: display }
}

function findNearestDisplay(displays: DisplayInfo[], point: { x: number; y: number }): DisplayInfo | undefined {
  let nearest: DisplayInfo | undefined
  let minDist = Infinity
  for (const d of displays) {
    const dist = centerDistSq(d, point)
    if (dist < minDist) {
      minDist = dist
      nearest = d
    }
  }
  return nearest
}

/** Squared distance from a display's center to a point (avoids sqrt). */
function centerDistSq(d: DisplayInfo, point: { x: number; y: number }): number {
  const cx = d.workArea.x + d.workArea.width / 2
  const cy = d.workArea.y + d.workArea.height / 2
  const dx = cx - point.x
  const dy = cy - point.y
  return dx * dx + dy * dy
}

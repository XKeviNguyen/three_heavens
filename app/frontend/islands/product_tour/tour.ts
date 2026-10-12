// Pure tour model: validated props, step availability, and card placement.
// Nothing here touches React; TourDialog and ProductTour own the lifecycle.

export interface TourStep {
  id: string
  title: string
  // One short idea per point, shown as separate lines.
  points: string[]
  // Element names (data-tour-target); empty for a centered step.
  targets: string[]
}

export type TourKind = "global" | "page"

export interface TourMessages {
  help: string
  full_tour: string
  page_tour: string
  next: string
  back: string
  skip: string
  finish: string
  close: string
  step_counter: string
  start_translation: string
  refreshing: string
  page_guides: string
  page_guides_on: string
  page_guides_off: string
  auto_note: string
  invite: { title: string; body: string; start: string; later: string }
}

// This page's guide: whether guides open by themselves for the account, the
// page context key ("projects:list", null when this view has none), and
// whether the account has already ended this guide.
export interface PageGuides {
  enabled: boolean
  key: string | null
  seen: boolean
  version: number
}

export interface ProductTourProps {
  version: number
  offer: boolean
  urls: { outcome: string; page: string; preference: string; start_translation: string }
  messages: TourMessages
  page_guides: PageGuides
  tours: { global: TourStep[]; page: TourStep[] | null }
}

// What a running tour shows for one step: anchored to a live element, or
// centered (no target, or a global step whose targets are all hidden).
export type ResolvedStep = { step: TourStep; target: HTMLElement } | { step: TourStep; target: null }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value)

const isString = (value: unknown): value is string => typeof value === "string"

function parseStep(value: unknown): TourStep | null {
  if (!isRecord(value)) return null
  const { id, title, points, targets } = value
  if (!isString(id) || !isString(title)) return null
  if (!Array.isArray(points) || points.length === 0 || points.length > 4 || !points.every((point) => isString(point) && point !== "")) return null
  if (!Array.isArray(targets) || !targets.every(isString)) return null
  return { id, title, points, targets }
}

function parseSteps(value: unknown): TourStep[] | null {
  if (!Array.isArray(value)) return null
  const steps = value.map(parseStep)
  return steps.length > 0 && steps.every((step): step is TourStep => step !== null) ? steps : null
}

function parseMessages(value: unknown): TourMessages | null {
  if (!isRecord(value) || !isRecord(value.invite)) return null
  const keys = ["help", "full_tour", "page_tour", "next", "back", "skip", "finish", "close", "step_counter", "start_translation", "refreshing", "page_guides", "page_guides_on", "page_guides_off", "auto_note"] as const
  if (!keys.every((key) => isString(value[key]))) return null
  const invite = value.invite
  if (![invite.title, invite.body, invite.start, invite.later].every(isString)) return null
  return value as unknown as TourMessages
}

// The island boundary: server props are checked once, so the components can
// rely on their types. Invalid props render nothing rather than a broken tour.
function parsePageGuides(value: unknown): PageGuides | null {
  if (!isRecord(value)) return null
  const { enabled, key, seen, version } = value
  if (typeof enabled !== "boolean" || typeof seen !== "boolean") return null
  if (key !== null && !(isString(key) && /^[a-z_]+:(list|form|detail)$/.test(key))) return null
  if (typeof version !== "number" || !Number.isInteger(version) || version < 1) return null
  return { enabled, key, seen, version }
}

export function parseProductTourProps(value: unknown): ProductTourProps | null {
  if (!isRecord(value) || !isRecord(value.urls) || !isRecord(value.tours)) return null
  const { version, offer, urls, tours } = value
  const pageGuides = parsePageGuides(value.page_guides)
  const messages = parseMessages(value.messages)
  const global = parseSteps(tours.global)
  const page = tours.page === null ? null : parseSteps(tours.page)
  if (typeof version !== "number" || !Number.isInteger(version) || version < 1) return null
  const { outcome, page: pageUrl, preference, start_translation } = urls
  if (typeof offer !== "boolean" || !isString(outcome) || !isString(pageUrl) || !isString(preference) || !isString(start_translation)) return null
  if (!messages || !global || !pageGuides || (tours.page !== null && !page)) return null
  return { version, offer, urls: { outcome, page: pageUrl, preference, start_translation }, messages, page_guides: pageGuides, tours: { global, page } }
}

function isVisible(element: HTMLElement): boolean {
  if (!element.isConnected) return false
  if (typeof element.checkVisibility === "function" && !element.checkVisibility({ visibilityProperty: true })) return false
  const rect = element.getBoundingClientRect()
  return rect.width > 0 && rect.height > 0
}

// The first visible element for the step's names, in order. Several elements
// may share a name (the desktop sidebar link and the mobile Menu button).
export function findTarget(step: TourStep): HTMLElement | null {
  for (const name of step.targets) {
    const candidates = document.querySelectorAll<HTMLElement>(`[data-tour-target~="${CSS.escape(name)}"]`)
    for (const candidate of Array.from(candidates)) {
      if (isVisible(candidate)) return candidate
    }
  }
  return null
}

// Steps this page can show now. A page step whose element is absent, hidden,
// or not permitted is left out; a global step falls back to centered.
export function resolveSteps(steps: TourStep[], kind: TourKind): ResolvedStep[] {
  const resolved: ResolvedStep[] = []
  for (const step of steps) {
    if (step.targets.length === 0) {
      resolved.push({ step, target: null })
      continue
    }
    const target = findTarget(step)
    if (target) resolved.push({ step, target })
    else if (kind === "global") resolved.push({ step, target: null })
  }
  return resolved
}

export function interpolate(template: string, values: Record<string, string | number>): string {
  return template.replace(/%\{(\w+)\}/g, (match, name: string) => (name in values ? String(values[name]) : match))
}

export interface Box {
  top: number
  left: number
  width: number
  height: number
}

export type Placement =
  | { kind: "centered" }
  // maxHeight is set on phones only: the room left on the side away from the
  // target, so the card does not cover it (its actions stay pinned and visible).
  | { kind: "sheet"; edge: "top" | "bottom"; maxHeight: number | null }
  | { kind: "anchored"; side: "top" | "bottom" | "left" | "right"; top: number; left: number; arrow: number }

const GAP = 12
const MARGIN = 12
// Below this width the card is a full-width sheet instead of a popover.
const SHEET_BREAKPOINT = 640
// A phone sheet never gets shorter than this, even if it then overlaps a tall
// target: title, a few lines of text, and the action row must fit.
const SHEET_MIN_HEIGHT = 240

const clamp = (value: number, min: number, max: number) => Math.min(Math.max(value, min), Math.max(min, max))

// Where the card goes for a target box, in viewport coordinates. A target
// narrower than the card (a navigation link, a button) gets the card beside
// it, so the column it sits in stays readable; a wide target (a page section)
// gets it below or above. If the card fits nowhere beside the target (a tall
// target, 200% zoom), it becomes a sheet on the edge away from it.
export function placeCard(target: Box | null, card: { width: number; height: number }, viewport: { width: number; height: number }): Placement {
  if (!target) return { kind: "centered" }
  const targetCenterY = target.top + target.height / 2
  if (viewport.width < SHEET_BREAKPOINT) {
    const edge = targetCenterY > viewport.height / 2 ? "top" : "bottom"
    const room = edge === "bottom" ? viewport.height - (target.top + target.height) - GAP - MARGIN : target.top - GAP - MARGIN
    const maxHeight = Math.min(viewport.height - MARGIN * 2, Math.max(room, SHEET_MIN_HEIGHT))
    return { kind: "sheet", edge, maxHeight: Math.floor(maxHeight) }
  }

  const centerX = target.left + target.width / 2
  const centerY = targetCenterY
  const horizontalLeft = clamp(centerX - card.width / 2, MARGIN, viewport.width - card.width - MARGIN)
  const verticalTop = clamp(centerY - card.height / 2, MARGIN, viewport.height - card.height - MARGIN)
  const fitsHorizontally = card.width + MARGIN * 2 <= viewport.width
  const fitsVertically = card.height + MARGIN * 2 <= viewport.height

  const below = (): Placement | null => {
    const top = target.top + target.height + GAP
    return fitsHorizontally && top + card.height + MARGIN <= viewport.height
      ? { kind: "anchored", side: "bottom", top, left: horizontalLeft, arrow: clamp(centerX - horizontalLeft, 20, card.width - 20) }
      : null
  }
  const above = (): Placement | null => {
    const top = target.top - GAP - card.height
    return fitsHorizontally && top >= MARGIN
      ? { kind: "anchored", side: "top", top, left: horizontalLeft, arrow: clamp(centerX - horizontalLeft, 20, card.width - 20) }
      : null
  }
  const right = (): Placement | null => {
    const left = target.left + target.width + GAP
    return fitsVertically && left + card.width + MARGIN <= viewport.width
      ? { kind: "anchored", side: "right", top: verticalTop, left, arrow: clamp(centerY - verticalTop, 20, card.height - 20) }
      : null
  }
  const left = (): Placement | null => {
    const position = target.left - GAP - card.width
    return fitsVertically && position >= MARGIN
      ? { kind: "anchored", side: "left", top: verticalTop, left: position, arrow: clamp(centerY - verticalTop, 20, card.height - 20) }
      : null
  }

  const order = target.width < card.width ? [right, left, below, above] : [below, above, right, left]
  for (const candidate of order) {
    const placement = candidate()
    if (placement) return placement
  }
  return { kind: "sheet", edge: centerY > viewport.height / 2 ? "top" : "bottom", maxHeight: null }
}

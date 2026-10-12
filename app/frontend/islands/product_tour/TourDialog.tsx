import { useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties } from "react"
import { findTarget, interpolate, placeCard, type Box, type Placement, type ResolvedStep, type TourKind, type TourMessages } from "./tour"

// One running tour. A native modal <dialog> provides the top layer, makes the
// rest of the page inert (nothing behind the tour can be clicked or
// submitted), and turns Escape into a cancel event. The spotlight is a
// transparent box whose shadow dims everything else.

export type TourOutcome = "completed" | "dismissed"

interface TourDialogProps {
  kind: TourKind
  steps: ResolvedStep[]
  messages: TourMessages
  // Offered on the last step of the global tour.
  finishLink: { href: string; label: string } | null
  onEnd: (outcome: TourOutcome) => void
}

const SPOTLIGHT_PADDING = 6
// The theme's overlay token (application.css), so light and dark both dim.
const DIM = "var(--th-scrim)"
// The spotlight's outline is part of its inline box-shadow (a ring utility
// would be overridden by it); the accent token follows the light/dark theme.
const OUTLINE = "0 0 0 2px var(--color-blue-500), 0 0 0 7px color-mix(in srgb, var(--color-blue-500) 28%, transparent)"

function prefersReducedMotion(): boolean {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches
}

function isShown(element: HTMLElement): boolean {
  if (!element.isConnected) return false
  const rect = element.getBoundingClientRect()
  return rect.width > 0 && rect.height > 0
}

function cardStyle(placement: Placement): CSSProperties {
  switch (placement.kind) {
    case "centered":
      return { top: "50%", left: "50%", transform: "translate(-50%, -50%)" }
    case "sheet":
      return { left: "50%", transform: "translateX(-50%)", [placement.edge]: 12, ...(placement.maxHeight ? { maxHeight: placement.maxHeight } : {}) }
    case "anchored":
      return { top: placement.top, left: placement.left }
  }
}

function arrowStyle(placement: Placement): CSSProperties | null {
  if (placement.kind !== "anchored") return null
  const offset = placement.arrow - 6
  switch (placement.side) {
    case "bottom":
      return { top: -7, left: offset, borderRightWidth: 0, borderBottomWidth: 0 }
    case "top":
      return { bottom: -7, left: offset, borderLeftWidth: 0, borderTopWidth: 0 }
    case "right":
      return { left: -7, top: offset, borderTopWidth: 0, borderRightWidth: 0 }
    case "left":
      return { right: -7, top: offset, borderBottomWidth: 0, borderLeftWidth: 0 }
  }
}

export function TourDialog({ kind, steps, messages, finishLink, onEnd }: TourDialogProps) {
  const [index, setIndex] = useState(0)
  const [layout, setLayout] = useState<{ box: Box | null; placement: Placement }>({ box: null, placement: { kind: "centered" } })
  const [announcement, setAnnouncement] = useState("")
  const dialogRef = useRef<HTMLDialogElement>(null)
  const cardRef = useRef<HTMLDivElement>(null)
  const primaryRef = useRef<HTMLButtonElement>(null)
  const direction = useRef<1 | -1>(1)
  const ended = useRef(false)
  const onEndRef = useRef(onEnd)
  onEndRef.current = onEnd
  const ids = useId()

  const total = steps.length
  const entry = steps[index]
  const isLast = index === total - 1

  function end(outcome: TourOutcome) {
    if (ended.current) return
    ended.current = true
    onEndRef.current(outcome)
  }

  function move(delta: 1 | -1) {
    direction.current = delta
    const next = index + delta
    if (next >= total) end("completed")
    else if (next >= 0) setIndex(next)
    else if (total > 1) {
      // Skipping backward past the first step: continue forward instead.
      direction.current = 1
      setIndex(index + 1)
    } else end("dismissed")
  }
  const moveRef = useRef(move)
  moveRef.current = move

  // Open as a modal once; focus the primary action. StrictMode runs this
  // twice, and dialog.close() queues its close event, so a close event is
  // only a dismissal if the dialog is still closed when it arrives (the
  // browser closed it, for example after repeated Escape presses).
  useLayoutEffect(() => {
    const dialog = dialogRef.current
    if (!dialog) return
    if (!dialog.open) dialog.showModal()
    primaryRef.current?.focus()
    const onCancel = (event: Event) => {
      event.preventDefault()
      end("dismissed")
    }
    const onClose = () => {
      if (!dialog.open) end("dismissed")
    }
    dialog.addEventListener("cancel", onCancel)
    dialog.addEventListener("close", onClose)
    return () => {
      dialog.removeEventListener("cancel", onCancel)
      dialog.removeEventListener("close", onClose)
      if (dialog.open) dialog.close()
    }
  }, [])

  // Follow the current step's element. Layout work is coalesced to one
  // measurement per animation frame and every listener and observer is
  // removed when the step changes or the tour ends.
  useLayoutEffect(() => {
    if (!entry) return
    let target = entry.target
    let frame = 0
    let scrolled = false
    const observer = new ResizeObserver(() => schedule())

    function measure() {
      frame = 0
      if (entry!.step.targets.length > 0 && (!target || !isShown(target))) {
        target = findTarget(entry!.step)
        if (target) observer.observe(target)
        else if (kind === "page") {
          // The element went away (removed, hidden, re-rendered): skip it.
          moveRef.current(direction.current)
          return
        }
      }
      if (target && !scrolled) {
        scrolled = true
        const rect = target.getBoundingClientRect()
        if (rect.top < 0 || rect.bottom > window.innerHeight) {
          target.scrollIntoView({ block: "center", inline: "nearest", behavior: prefersReducedMotion() ? "auto" : "smooth" })
        }
      }
      const rect = target?.getBoundingClientRect()
      const box = rect ? { top: rect.top, left: rect.left, width: rect.width, height: rect.height } : null
      const card = cardRef.current
      const size = { width: card?.offsetWidth ?? 352, height: card?.offsetHeight ?? 220 }
      const viewport = { width: document.documentElement.clientWidth, height: window.innerHeight }
      setLayout({ box, placement: placeCard(box, size, viewport) })
    }

    function schedule() {
      if (frame === 0) frame = window.requestAnimationFrame(measure)
    }

    measure()
    if (target) observer.observe(target)
    if (cardRef.current) observer.observe(cardRef.current)
    observer.observe(document.documentElement)
    window.addEventListener("resize", schedule)
    window.visualViewport?.addEventListener("resize", schedule)
    window.addEventListener("scroll", schedule, { capture: true, passive: true })
    return () => {
      if (frame !== 0) window.cancelAnimationFrame(frame)
      observer.disconnect()
      window.removeEventListener("resize", schedule)
      window.visualViewport?.removeEventListener("resize", schedule)
      window.removeEventListener("scroll", schedule, { capture: true })
    }
  }, [entry, kind])

  // The dialog's name and description are read when it opens; later steps
  // are announced here, with focus left on the button that was pressed.
  const counter = interpolate(messages.step_counter, { current: index + 1, total })
  const firstRender = useRef(true)
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false
      return
    }
    if (entry) setAnnouncement(`${counter}. ${entry.step.title}. ${entry.step.body}`)
  }, [index])

  if (!entry) return null

  const { box, placement } = layout
  const arrow = arrowStyle(placement)
  const motion = prefersReducedMotion() ? "" : "transition-[top,left,width,height] duration-200 ease-out"
  const eyebrow = kind === "global" ? messages.full_tour : messages.page_tour

  return (
    <dialog
      ref={dialogRef}
      aria-labelledby={`${ids}-title`}
      aria-describedby={`${ids}-body`}
      data-testid="product-tour"
      data-tour-kind={kind}
      className="fixed inset-0 m-0 h-dvh max-h-none w-screen max-w-none overflow-hidden border-0 bg-transparent p-0 backdrop:bg-transparent"
    >
      {box ? (
        <div
          aria-hidden="true"
          data-testid="product-tour-spotlight"
          className={`pointer-events-none fixed rounded-xl ${motion}`}
          style={{
            top: box.top - SPOTLIGHT_PADDING,
            left: box.left - SPOTLIGHT_PADDING,
            width: box.width + SPOTLIGHT_PADDING * 2,
            height: box.height + SPOTLIGHT_PADDING * 2,
            boxShadow: `${OUTLINE}, 0 0 0 9999px ${DIM}`
          }}
        >
          {/* A soft static halo: endless motion would distract (and needs a
              pause control under WCAG 2.2.2), so the outline does the work. */}
          <span className="absolute -inset-1 rounded-[14px] shadow-[0_0_24px_4px_color-mix(in_srgb,var(--color-blue-500)_35%,transparent)]" />
        </div>
      ) : (
        <div aria-hidden="true" className="fixed inset-0" style={{ background: DIM }} />
      )}

      <div
        ref={cardRef}
        data-testid="product-tour-card"
        data-placement={placement.kind}
        // Size never depends on anchored placement, so a measurement cannot
        // flip it back and forth; only phone sheets (always sheets) are capped
        // to the room beside the target. The header and the action row are
        // pinned: only the text scrolls, so Back, Next, Skip and Finish stay
        // visible on short screens and at 200% zoom.
        className="fixed flex max-h-[calc(100dvh-1.5rem)] w-[min(24rem,calc(100vw-1.5rem))] flex-col rounded-xl border border-slate-200 bg-white text-slate-900 shadow-(--th-shadow-float)"
        style={cardStyle(placement)}
      >
        {arrow ? (
          <span aria-hidden="true" className="absolute size-3 rotate-45 border border-slate-200 bg-white" style={arrow} />
        ) : null}
        <div className="shrink-0 px-5 pt-4">
          <div className="flex items-center justify-between gap-3">
            <p className="text-[13px] font-medium tracking-[0.01em] text-slate-600">{eyebrow}</p>
            <button
              type="button"
              onClick={() => end("dismissed")}
              aria-label={messages.close}
              className="-mr-2 inline-flex size-10 shrink-0 items-center justify-center rounded-lg text-slate-500 hover:bg-slate-100 hover:text-slate-950 pointer-coarse:size-11"
            >
              <svg className="size-4" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
                <path strokeLinecap="round" d="M5 5l10 10M15 5L5 15" />
              </svg>
            </button>
          </div>
          <div className="mt-1 flex items-center gap-3">
            <ol aria-hidden="true" className="flex flex-1 gap-1">
              {steps.map((_, step) => (
                <li key={step} className={`h-1.5 flex-1 rounded-full ${step <= index ? "bg-blue-600" : "bg-slate-300"}`} />
              ))}
            </ol>
            <p className="shrink-0 text-xs font-semibold tabular-nums text-slate-600">{counter}</p>
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-4 pt-4">
          <h2 id={`${ids}-title`} className="text-xl font-semibold leading-snug tracking-tight text-slate-950">
            {entry.step.title}
          </h2>
          <p id={`${ids}-body`} className="mt-2 text-[15px] leading-6 text-slate-700">
            {entry.step.body}
          </p>
          {isLast && finishLink ? (
            <a
              href={finishLink.href}
              onClick={() => end("completed")}
              className="mt-3 inline-flex min-h-11 items-center gap-1.5 text-sm font-semibold text-blue-700 underline-offset-4 hover:underline"
            >
              {finishLink.label}
              <span aria-hidden="true">→</span>
            </a>
          ) : null}
        </div>
        <div className="flex shrink-0 flex-wrap items-center justify-between gap-2 rounded-b-xl border-t border-slate-200 bg-slate-50 px-5 py-3">
          <button
            type="button"
            onClick={() => end("dismissed")}
            className="min-h-11 rounded-lg px-2 py-2 text-sm font-semibold text-slate-600 hover:bg-slate-100 hover:text-slate-950"
          >
            {messages.skip}
          </button>
          <div className="ml-auto flex gap-2">
            {/* Never removed or disabled on the first step, so focus is not lost. */}
            <button
              type="button"
              aria-disabled={index === 0}
              onClick={() => index > 0 && move(-1)}
              className="min-h-11 rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50 aria-disabled:cursor-not-allowed aria-disabled:opacity-40"
            >
              {messages.back}
            </button>
            <button
              ref={primaryRef}
              type="button"
              onClick={() => move(1)}
              className="min-h-11 rounded-lg bg-blue-600 px-5 py-2 text-sm font-semibold text-white shadow-sm hover:bg-blue-700"
            >
              {isLast ? messages.finish : messages.next}
            </button>
          </div>
        </div>
        <p aria-live="polite" className="sr-only">
          {announcement}
        </p>
      </div>
    </dialog>
  )
}

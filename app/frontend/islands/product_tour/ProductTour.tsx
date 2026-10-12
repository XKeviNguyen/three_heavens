import { useEffect, useId, useLayoutEffect, useRef, useState, type FocusEvent, type KeyboardEvent } from "react"
import { createPortal } from "react-dom"
import { TourDialog, type TourOutcome } from "./TourDialog"
import { parseProductTourProps, resolveSteps, type ProductTourProps, type ResolvedStep, type TourKind, type TourMessages, type TourStep } from "./tour"

// Help → Full product tour / Tour this page, and the one-time invitation for
// accounts that have not resolved the current tour version. The island lives
// in the sidebar; the invitation and the tour render into <body> so a closed
// mobile drawer cannot hide them. Turbo visits unmount the island (mount.tsx),
// which removes any open tour with it.
//
// The account's outcome is the server's (users.product_tour_*). It is written
// once, only when an offered global tour or its invitation is resolved.

type Session = { phase: "idle" } | { phase: "running"; kind: TourKind; steps: ResolvedStep[] }

// The version the server has accepted an outcome for in this document. A
// Turbo restoration visit can render a cached page whose props still say
// "offer"; this keeps it from inviting again. It is set only after the server
// answers 2xx, so a failed request lets the next page offer the tour again.
// Signed-out pages have no tour island, so signing out (the only way to switch
// accounts) forgets it, and a response for the previous account (a different
// session) is ignored.
// sendingVersion covers the time the request is in flight, so a page reached
// right away (or prefetched before the write committed) does not invite again;
// it is cleared if the request fails.
let resolvedVersion = 0
let sendingVersion = 0
let signedInSession = 0
document.addEventListener("turbo:load", () => {
  if (!document.querySelector("[data-react-island='product-tour']")) {
    resolvedVersion = 0
    sendingVersion = 0
    signedInSession += 1
  }
})

// Pages watching running AI work reload themselves every few seconds
// (<meta http-equiv="refresh">), which would cut a tour short; tours wait until
// the page stops refreshing.
function pageAutoRefreshes(): boolean {
  return document.querySelector('meta[http-equiv="refresh" i]') !== null
}

// The tour closes on the first click of Finish, Skip, or Close. The second
// click of a double click must not reach whatever was under the card, which
// could be a submit button. The guard lasts only until the next click.
function swallowSecondClick() {
  const guard = (event: MouseEvent) => {
    document.removeEventListener("click", guard, true)
    if (event.detail > 1) {
      event.preventDefault()
      event.stopPropagation()
    }
  }
  document.addEventListener("click", guard, true)
}

function csrfToken(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

function focusFirstShown(candidates: (HTMLElement | null)[]) {
  for (const element of candidates) {
    if (element?.isConnected && element.getClientRects().length > 0) {
      element.focus()
      return
    }
  }
}

export function ProductTour(rawProps: Record<string, unknown>) {
  const [props] = useState(() => parseProductTourProps(rawProps))
  if (!props) {
    console.error("Product tour props are invalid; the tour is unavailable on this page.")
    return null
  }
  return <ProductTourIsland {...props} />
}

function ProductTourIsland({ version, offer, urls, messages, tours }: ProductTourProps) {
  const [session, setSession] = useState<Session>({ phase: "idle" })
  const [offerPending, setOfferPending] = useState(() => offer && Math.max(resolvedVersion, sendingVersion) < version)
  const [refreshing] = useState(pageAutoRefreshes)
  const [menuOpen, setMenuOpen] = useState(false)
  const helpButton = useRef<HTMLButtonElement>(null)
  const menuRoot = useRef<HTMLDivElement>(null)
  const restoreFocus = useRef(false)
  const ids = useId()

  function recordOutcome(outcome: TourOutcome) {
    if (!offerPending) return
    // Hidden on this page at once; remembered across pages only once the
    // server has recorded it (see resolvedVersion).
    setOfferPending(false)
    const sentIn = signedInSession
    sendingVersion = Math.max(sendingVersion, version)
    // keepalive lets the write finish if the user follows a link right away.
    void fetch(urls.outcome, {
      method: "PATCH",
      keepalive: true,
      credentials: "same-origin",
      redirect: "manual",
      headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
      body: JSON.stringify({ product_tour: { outcome, version } })
    })
      .then((response) => response.ok)
      // Not recorded (offline, signed out, refused): the next page offers it again.
      .catch(() => false)
      .then((recorded) => {
        if (sentIn !== signedInSession) return
        if (recorded) resolvedVersion = Math.max(resolvedVersion, version)
        else sendingVersion = 0
      })
  }

  function start(kind: TourKind) {
    const steps = kind === "global" ? tours.global : tours.page
    if (refreshing) return
    setMenuOpen(false)
    if (!steps || session.phase === "running") return
    // Closes the mobile navigation drawer (sidebar controller) first, so the
    // steps are resolved against what will actually be visible.
    document.dispatchEvent(new CustomEvent("product-tour:start"))
    const resolved = resolveSteps(steps, kind)
    if (resolved.length > 0) setSession({ phase: "running", kind, steps: resolved })
  }

  function end(outcome: TourOutcome) {
    if (session.phase !== "running") return
    if (session.kind === "global") recordOutcome(outcome)
    swallowSecondClick()
    restoreFocus.current = true
    setSession({ phase: "idle" })
  }

  // After a tour ends or the invitation is dismissed, focus returns to Help
  // (or the mobile Menu button) instead of the top of the page.
  useEffect(() => {
    if (session.phase !== "idle" || offerPending || !restoreFocus.current) return
    restoreFocus.current = false
    focusFirstShown([
      helpButton.current,
      document.querySelector<HTMLElement>("[data-sidebar-target='trigger']"),
      document.getElementById("main-content")
    ])
  }, [session, offerPending])

  // A press outside the open menu closes it, like the appearance menu.
  useEffect(() => {
    if (!menuOpen) return
    const close = (event: PointerEvent) => {
      if (!menuRoot.current?.contains(event.target as Node)) setMenuOpen(false)
    }
    document.addEventListener("pointerdown", close)
    return () => document.removeEventListener("pointerdown", close)
  }, [menuOpen])

  // Tabbing out of the menu closes it. Focus moving to nothing (a click on a
  // button that does not take focus, as in Safari) is left to pointerdown.
  function onMenuBlur(event: FocusEvent) {
    const next = event.relatedTarget
    if (menuOpen && next instanceof Node && !menuRoot.current?.contains(next)) setMenuOpen(false)
  }

  function onMenuKeyDown(event: KeyboardEvent) {
    if (event.key !== "Escape" || !menuOpen) return
    event.stopPropagation()
    setMenuOpen(false)
    helpButton.current?.focus()
  }

  return (
    <div ref={menuRoot} onKeyDown={onMenuKeyDown} onBlur={onMenuBlur}>
      {/* A compact icon button beside the language and appearance controls,
          so the sidebar footer keeps its height and the navigation its room. */}
      <button
        ref={helpButton}
        type="button"
        title={messages.help}
        aria-label={messages.help}
        aria-expanded={menuOpen}
        aria-controls={`${ids}-menu`}
        onClick={() => setMenuOpen((open) => !open)}
        className="grid size-10 place-items-center rounded-[10px] border border-slate-300 text-slate-700 hover:bg-slate-100 hover:text-slate-950 aria-expanded:bg-slate-100 pointer-coarse:size-11"
      >
        <svg className="size-[18px]" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
          <circle cx="10" cy="10" r="7" />
          <path strokeLinecap="round" d="M8.1 8a2 2 0 1 1 2.9 1.8c-.6.3-1 .8-1 1.5v.4" />
          <circle cx="10" cy="14.2" r=".4" fill="currentColor" />
        </svg>
      </button>
      <ul id={`${ids}-menu`} hidden={!menuOpen} className="appearance-menu-panel">
        <li>
          <button type="button" aria-disabled={refreshing} aria-describedby={refreshing ? `${ids}-refreshing` : undefined} onClick={() => start("global")} className="appearance-option aria-disabled:opacity-50">
            {messages.full_tour}
          </button>
        </li>
        {tours.page ? (
          <li>
            <button type="button" aria-disabled={refreshing} aria-describedby={refreshing ? `${ids}-refreshing` : undefined} onClick={() => start("page")} className="appearance-option aria-disabled:opacity-50">
              {messages.page_tour}
            </button>
          </li>
        ) : null}
        {refreshing ? (
          <li id={`${ids}-refreshing`} className="max-w-56 px-2.5 py-1.5 text-xs text-slate-600">
            {messages.refreshing}
          </li>
        ) : null}
      </ul>

      {offerPending && !refreshing && session.phase === "idle"
        ? createPortal(
            <InviteDialog
              messages={messages}
              steps={tours.global}
              onStart={() => {
                start("global")
                // The first tour card opens where the invitation was; the second
                // click of a double click must not press its Next button.
                swallowSecondClick()
              }}
              onLater={() => {
                recordOutcome("dismissed")
                restoreFocus.current = true
                // The dialog closes on the first click; like the tour's own
                // buttons, a double click must not reach the page.
                swallowSecondClick()
              }}
            />,
            document.body
          )
        : null}

      {session.phase === "running"
        ? createPortal(
            <TourDialog
              key={session.kind}
              kind={session.kind}
              steps={session.steps}
              messages={messages}
              finishLink={session.kind === "global" ? { href: urls.start_translation, label: messages.start_translation } : null}
              onEnd={end}
            />,
            document.body
          )
        : null}
    </div>
  )
}

// The one-time welcome: a modal dialog, so it is noticed and the page behind it
// is inert until the account answers. Escape is the same as Not now; Help can
// replay the tour at any time. The step titles preview what the tour covers.
function InviteDialog({ messages, steps, onStart, onLater }: { messages: TourMessages; steps: TourStep[]; onStart: () => void; onLater: () => void }) {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const primaryRef = useRef<HTMLButtonElement>(null)
  const onLaterRef = useRef(onLater)
  onLaterRef.current = onLater
  const ids = useId()

  useLayoutEffect(() => {
    const dialog = dialogRef.current
    if (!dialog) return
    if (!dialog.open) dialog.showModal()
    primaryRef.current?.focus()
    const onCancel = (event: Event) => {
      event.preventDefault()
      onLaterRef.current()
    }
    dialog.addEventListener("cancel", onCancel)
    // Listeners go first, so closing on unmount (the tour starting, a Turbo
    // visit) is never mistaken for an answer.
    return () => {
      dialog.removeEventListener("cancel", onCancel)
      if (dialog.open) dialog.close()
    }
  }, [])

  return (
    <dialog
      ref={dialogRef}
      aria-labelledby={`${ids}-title`}
      aria-describedby={`${ids}-body`}
      data-testid="product-tour-invite"
      className="fixed inset-0 m-auto open:flex max-h-[calc(100dvh-1.5rem)] w-[min(32rem,calc(100vw-1.5rem))] flex-col overflow-hidden rounded-3xl border border-slate-200 bg-white p-0 text-slate-900 shadow-[0_32px_80px_-16px_rgb(2_6_23/0.55)] backdrop:bg-[rgb(2_6_23/0.62)]"
    >
      <div className="min-h-0 flex-1 overflow-y-auto px-6 pb-2 pt-6 sm:px-8 sm:pt-8">
        <span aria-hidden="true" className="grid size-12 place-items-center rounded-2xl bg-blue-50 text-blue-700 ring-1 ring-blue-100">
          <svg className="size-6" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
            <circle cx="12" cy="12" r="9" />
            <path strokeLinejoin="round" d="M15.5 8.5l-2 5-5 2 2-5 5-2z" />
          </svg>
        </span>
        <h2 id={`${ids}-title`} className="mt-5 text-2xl font-semibold leading-tight tracking-tight text-slate-950">
          {messages.invite.title}
        </h2>
        <p id={`${ids}-body`} className="mt-2 text-[15px] leading-7 text-slate-700">
          {messages.invite.body}
        </p>
        <ol className="mt-5 grid gap-x-5 gap-y-2.5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-800 sm:grid-cols-2">
          {steps.map((step, index) => (
            <li key={step.id} className="flex items-start gap-2.5">
              <span aria-hidden="true" className="mt-px grid size-5 shrink-0 place-items-center rounded-full bg-blue-600 text-[11px] font-semibold text-white">
                {index + 1}
              </span>
              <span className="leading-5">{step.title}</span>
            </li>
          ))}
        </ol>
      </div>
      <div className="flex shrink-0 flex-col gap-2 border-t border-slate-200 px-6 py-4 sm:flex-row-reverse sm:px-8">
        <button
          ref={primaryRef}
          type="button"
          onClick={onStart}
          className="min-h-11 rounded-xl bg-blue-600 px-5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-blue-700"
        >
          {messages.invite.start}
        </button>
        <button
          type="button"
          onClick={onLater}
          className="min-h-11 rounded-xl border border-slate-300 bg-white px-5 py-2.5 text-sm font-semibold text-slate-800 hover:bg-slate-50"
        >
          {messages.invite.later}
        </button>
      </div>
    </dialog>
  )
}

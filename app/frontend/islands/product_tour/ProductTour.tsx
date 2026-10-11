import { useEffect, useId, useRef, useState, type FocusEvent, type KeyboardEvent } from "react"
import { createPortal } from "react-dom"
import { TourDialog, type TourOutcome } from "./TourDialog"
import { parseProductTourProps, resolveSteps, type ProductTourProps, type ResolvedStep, type TourKind } from "./tour"

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
let inviteAnnounced = false
let signedInSession = 0
document.addEventListener("turbo:load", () => {
  if (!document.querySelector("[data-react-island='product-tour']")) {
    resolvedVersion = 0
    sendingVersion = 0
    inviteAnnounced = false
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
  const [announcement, setAnnouncement] = useState("")
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
        else {
          sendingVersion = 0
          inviteAnnounced = false
        }
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

  useEffect(() => {
    if (session.phase !== "idle" || !restoreFocus.current) return
    restoreFocus.current = false
    focusFirstShown([
      helpButton.current,
      document.querySelector<HTMLElement>("[data-sidebar-target='trigger']"),
      document.getElementById("main-content")
    ])
  }, [session])

  // The invitation is appended to <body>, out of the reading order; say once
  // per document that it is there.
  useEffect(() => {
    if (!offerPending || refreshing || inviteAnnounced) return
    inviteAnnounced = true
    setAnnouncement(`${messages.invite.title} ${messages.invite.body}`)
  }, [offerPending, refreshing, messages])

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

      <p role="status" className="sr-only">
        {announcement}
      </p>

      {offerPending && !refreshing && session.phase === "idle"
        ? createPortal(
            <aside
              aria-labelledby={`${ids}-invite-title`}
              data-testid="product-tour-invite"
              className="fixed inset-x-4 bottom-4 z-20 rounded-2xl border border-slate-200 bg-white p-5 text-slate-900 shadow-xl sm:left-auto sm:w-96"
            >
              <h2 id={`${ids}-invite-title`} className="text-base font-semibold text-slate-950">
                {messages.invite.title}
              </h2>
              <p className="mt-1 text-sm leading-6 text-slate-700">{messages.invite.body}</p>
              <div className="mt-4 flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={() => start("global")}
                  className="min-h-11 rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700"
                >
                  {messages.invite.start}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    recordOutcome("dismissed")
                    // The card disappears on the first click; like the tour's
                    // own buttons, a double click must not reach the page.
                    swallowSecondClick()
                  }}
                  className="min-h-11 rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50"
                >
                  {messages.invite.later}
                </button>
              </div>
            </aside>,
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

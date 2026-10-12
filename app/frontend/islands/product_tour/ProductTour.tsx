import { useEffect, useId, useLayoutEffect, useRef, useState, type FocusEvent, type KeyboardEvent, type ReactNode } from "react"
import { createPortal } from "react-dom"
import { TourDialog, type TourOutcome } from "./TourDialog"
import { parseProductTourProps, resolveSteps, type ProductTourProps, type ResolvedStep, type TourKind, type TourMessages, type TourStep } from "./tour"

// Help (top of the sidebar, and in the mobile header) → the product tour, this
// page's guide, and whether page guides open by themselves; the one-time
// invitation for accounts that have not resolved the current tour version;
// and a page's guide opening by itself the first time the account visits it.
// The island lives in the sidebar; the mobile header's Help button is a portal
// of the same island, so both share one state. The invitation and tours render
// into <body> so a closed mobile drawer cannot hide them. Turbo visits unmount
// the island (mount.tsx), which removes any open tour with it.
//
// All durable state is the server's: users.product_tour_* (the global offer
// and the page-guides switch) and one row per page guide the account ended.
// Guides only teach: nothing here clicks, submits, or changes anything else.

type Session = { phase: "idle" } | { phase: "running"; kind: TourKind; steps: ResolvedStep[]; auto: boolean }
type Anchor = "sidebar" | "header"

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
// The same for page guides, by page key: a cached page whose props still say
// "not seen" must not open its guide again once it has ended.
const recordedPageKeys = new Set<string>()
const sendingPageKeys = new Set<string>()
// The page-guides switch as last accepted by the server in this document, for
// cached pages (a Turbo preview, Back/Forward) rendered before it changed.
// Freshly rendered pages trust their props, which another tab may have changed.
let pageGuidesAccepted: boolean | null = null
// Bumped by every press of the switch, so a late answer to the welcome tour's
// outcome never overrides a newer choice.
let preferenceChanges = 0
// The welcome tour's outcome write; a switch press waits for it, so the server
// applies the account's explicit choice last.
let outcomeWrite: Promise<unknown> = Promise.resolve()
let restoringVisit = false
document.addEventListener("turbo:visit", (event) => {
  restoringVisit = (event as CustomEvent<{ action?: string }>).detail?.action === "restore"
})
function renderedFromCache(): boolean {
  return restoringVisit || document.documentElement.hasAttribute("data-turbo-preview")
}
// Help's border plays its short animation on the first page of a visit only.
let helpIntroPlayed = false
document.addEventListener("turbo:load", () => {
  if (!document.querySelector("[data-react-island='product-tour']")) {
    resolvedVersion = 0
    sendingVersion = 0
    recordedPageKeys.clear()
    sendingPageKeys.clear()
    pageGuidesAccepted = null
    helpIntroPlayed = false
    signedInSession += 1
  }
})

// Pages watching running AI work reload themselves every few seconds
// (<meta http-equiv="refresh">), which would cut a tour short; tours wait until
// the page stops refreshing.
function pageAutoRefreshes(): boolean {
  return document.querySelector('meta[http-equiv="refresh" i]') !== null
}

// A guide never opens by itself over a field the user is already typing in.
function isEditing(element: Element | null): boolean {
  if (!(element instanceof HTMLElement)) return false
  return element.isContentEditable || element.matches("input:not([type=button]):not([type=submit]):not([type=checkbox]):not([type=radio]), textarea, select")
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

// keepalive lets a write finish if the user follows a link right away.
// Resolves to the response when the server accepted the write, else null.
function send(url: string, body: unknown): Promise<Response | null> {
  return fetch(url, {
    method: "PATCH",
    keepalive: true,
    credentials: "same-origin",
    redirect: "manual",
    headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify(body)
  })
    .then((response) => (response.ok ? response : null))
    .catch(() => null)
}

function focusFirstShown(candidates: (HTMLElement | null)[]) {
  for (const element of candidates) {
    if (element?.isConnected && element.getClientRects().length > 0) {
      element.focus()
      return
    }
  }
}

function HelpIcon() {
  return (
    <svg className="size-[18px] shrink-0" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true">
      <circle cx="10" cy="10" r="7.25" />
      <path strokeLinecap="round" d="M8.1 8a2 2 0 1 1 2.9 1.8c-.6.3-1 .8-1 1.5v.4" />
      <circle cx="10" cy="14.2" r=".45" fill="currentColor" />
    </svg>
  )
}

// A thin seven-colour border with a soft glow (application.css, .th-neon).
function NeonFrame({ intro, children }: { intro: boolean; children: ReactNode }) {
  return (
    <span className={`th-neon${intro ? " th-neon--intro" : ""}`}>
      <span aria-hidden="true" className="th-neon__glow" />
      <span aria-hidden="true" className="th-neon__ring" />
      {children}
    </span>
  )
}

export function ProductTour(rawProps: Record<string, unknown>) {
  const [props] = useState(() => parseProductTourProps(rawProps))
  if (!props) {
    console.error("Product tour props are invalid; the tour is unavailable on this page.")
    return null
  }
  return <ProductTourIsland {...props} />
}

function ProductTourIsland({ version, offer, urls, messages, page_guides: pageGuides, tours }: ProductTourProps) {
  const [session, setSession] = useState<Session>({ phase: "idle" })
  const [offerPending, setOfferPending] = useState(() => offer && Math.max(resolvedVersion, sendingVersion) < version)
  const [refreshing] = useState(pageAutoRefreshes)
  const [guidesEnabled, setGuidesEnabled] = useState(() => (renderedFromCache() ? pageGuidesAccepted : null) ?? pageGuides.enabled)
  const [menuAnchor, setMenuAnchor] = useState<Anchor | null>(null)
  const [headerSlot] = useState(() => document.getElementById("product-tour-header-slot"))
  // Played once the welcome window is answered, so it is not spent unseen
  // behind it.
  const [intro, setIntro] = useState(false)
  const helpButton = useRef<HTMLButtonElement>(null)
  const headerButton = useRef<HTMLButtonElement>(null)
  const menuRoot = useRef<HTMLDivElement>(null)
  const headerRoot = useRef<HTMLDivElement>(null)
  const restoreFocus = useRef(false)
  const preferenceInFlight = useRef(false)
  const sessionRef = useRef(session)
  sessionRef.current = session
  const ids = useId()

  function recordOutcome(outcome: TourOutcome) {
    if (!offerPending) return
    // Hidden on this page at once; remembered across pages only once the
    // server has recorded it (see resolvedVersion).
    setOfferPending(false)
    const sentIn = signedInSession
    const changesBefore = preferenceChanges
    sendingVersion = Math.max(sendingVersion, version)
    outcomeWrite = send(urls.outcome, { product_tour: { outcome, version } })
      .then((response) => response?.json() as Promise<unknown> | undefined)
      .catch(() => undefined)
      .then((answer) => {
        if (sentIn !== signedInSession) return
        if (answer === undefined) {
          // Not recorded (offline, signed out, refused): the next page offers it again.
          sendingVersion = 0
          return
        }
        resolvedVersion = Math.max(resolvedVersion, version)
        // Completing a first tour turns page guides on, unless another tab
        // answered first: the server says which.
        const guides = (answer as { page_guides?: unknown } | null)?.page_guides
        if (typeof guides === "boolean" && changesBefore === preferenceChanges) {
          pageGuidesAccepted = guides
          setGuidesEnabled(guides)
        }
      })
  }

  // Remembers that this page's guide ended, once per page key. A failed write
  // is forgotten, so the guide may open by itself again on a later visit.
  function recordPageOutcome(outcome: TourOutcome) {
    const key = pageGuides.key
    if (!key || pageGuides.seen || recordedPageKeys.has(key) || sendingPageKeys.has(key)) return
    sendingPageKeys.add(key)
    const sentIn = signedInSession
    void send(urls.page, { product_tour_page: { key, outcome, version: pageGuides.version } }).then((recorded) => {
      if (sentIn !== signedInSession) return
      sendingPageKeys.delete(key)
      if (recorded) recordedPageKeys.add(key)
    })
  }

  function toggleGuides() {
    if (preferenceInFlight.current) return
    preferenceInFlight.current = true
    preferenceChanges += 1
    const next = !guidesEnabled
    setGuidesEnabled(next)
    const sentIn = signedInSession
    void outcomeWrite.then(() => send(urls.preference, { product_tour_preference: { page_guides: next } })).then((saved) => {
      preferenceInFlight.current = false
      if (sentIn !== signedInSession) return
      if (saved) pageGuidesAccepted = next
      else setGuidesEnabled(!next)
    })
  }

  function start(kind: TourKind, auto = false) {
    const steps = kind === "global" ? tours.global : tours.page
    if (refreshing) return
    setMenuAnchor(null)
    if (!steps || session.phase === "running") return
    // Closes the mobile navigation drawer (sidebar controller) first, so the
    // steps are resolved against what will actually be visible.
    document.dispatchEvent(new CustomEvent("product-tour:start"))
    const resolved = resolveSteps(steps, kind)
    // A guide that opens by itself must have something on this page to point at.
    if (auto && !resolved.some((entry) => entry.target !== null)) return
    if (resolved.length > 0) setSession({ phase: "running", kind, steps: resolved, auto })
  }

  function end(outcome: TourOutcome) {
    if (session.phase !== "running") return
    if (session.kind === "global") recordOutcome(outcome)
    else recordPageOutcome(outcome)
    swallowSecondClick()
    restoreFocus.current = true
    setSession({ phase: "idle" })
  }

  // This page's guide opens by itself on the account's first visit, decided
  // when the page appears: not while the invitation is waiting, and only on a
  // quiet, fully rendered page: not over
  // another dialog, not while the user is typing, not on a Turbo preview of a
  // cached page, and not on a page that keeps refreshing.
  useEffect(() => {
    const key = pageGuides.key
    if (!guidesEnabled || !key || pageGuides.seen || offerPending || refreshing) return
    if (recordedPageKeys.has(key) || sendingPageKeys.has(key)) return
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    if (document.querySelector("dialog[open]") || isEditing(document.activeElement)) return
    start("page", true)
    // Decided once, when the page appears.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (offerPending || helpIntroPlayed || document.documentElement.hasAttribute("data-turbo-preview")) return
    helpIntroPlayed = true
    setIntro(true)
  }, [offerPending])

  // Leaving the page (a link, Back, a reload) while its guide is open counts as
  // dismissing it, so it does not open by itself again.
  useEffect(() => {
    const leave = () => {
      const current = sessionRef.current
      if (current.phase === "running" && current.kind === "page") recordPageOutcome("dismissed")
    }
    window.addEventListener("pagehide", leave)
    return () => {
      window.removeEventListener("pagehide", leave)
      leave()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // After a tour ends or the invitation is dismissed, focus returns to Help
  // (or the mobile Menu button) instead of the top of the page.
  useEffect(() => {
    if (session.phase !== "idle" || offerPending || !restoreFocus.current) return
    restoreFocus.current = false
    focusFirstShown([
      headerButton.current,
      helpButton.current,
      document.querySelector<HTMLElement>("[data-sidebar-target='trigger']"),
      document.getElementById("main-content")
    ])
  }, [session, offerPending])

  // A press outside the open menu closes it, like the appearance menu.
  useEffect(() => {
    if (!menuAnchor) return
    const close = (event: PointerEvent) => {
      const target = event.target as Node
      if (!menuRoot.current?.contains(target) && !headerRoot.current?.contains(target)) setMenuAnchor(null)
    }
    document.addEventListener("pointerdown", close)
    return () => document.removeEventListener("pointerdown", close)
  }, [menuAnchor])

  // Tabbing out of the menu closes it. Focus moving to nothing (a click on a
  // button that does not take focus, as in Safari) is left to pointerdown.
  function onMenuBlur(event: FocusEvent) {
    const next = event.relatedTarget
    if (menuAnchor && next instanceof Node && !menuRoot.current?.contains(next) && !headerRoot.current?.contains(next)) setMenuAnchor(null)
  }

  function onMenuKeyDown(event: KeyboardEvent) {
    if (event.key !== "Escape" || !menuAnchor) return
    event.stopPropagation()
    const opener = menuAnchor === "header" ? headerButton.current : helpButton.current
    setMenuAnchor(null)
    opener?.focus()
  }

  const toggleMenu = (anchor: Anchor) => setMenuAnchor((open) => (open === anchor ? null : anchor))

  const menu = (anchor: Anchor) => (
    <ul id={`${ids}-menu`} role="list" hidden={menuAnchor !== anchor} className={`appearance-menu-panel th-help-menu th-help-menu--${anchor}`}>
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
      <li aria-hidden="true" className="my-1 border-t border-slate-200" />
      <li>
        <button type="button" aria-pressed={guidesEnabled} onClick={toggleGuides} className="appearance-option">
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
            <path strokeLinecap="round" strokeLinejoin="round" d="M3.5 8.5l3 3 6-7" />
          </svg>
          <span className="min-w-0 flex-1 [word-break:auto-phrase]">{messages.page_guides}</span>
          {/* The state in words too; the button's name stays the same. */}
          <span aria-hidden="true" className="text-xs font-medium text-slate-500">
            {guidesEnabled ? messages.page_guides_on : messages.page_guides_off}
          </span>
        </button>
      </li>
      {refreshing ? (
        <li id={`${ids}-refreshing`} className="max-w-56 px-2.5 py-1.5 text-xs text-slate-600">
          {messages.refreshing}
        </li>
      ) : null}
    </ul>
  )

  return (
    <div ref={menuRoot} onKeyDown={onMenuKeyDown} onBlur={onMenuBlur}>
      {/* A labelled button at the top of the sidebar, where it is seen first. */}
      <NeonFrame intro={intro}>
        <button
          ref={helpButton}
          type="button"
          aria-expanded={menuAnchor === "sidebar"}
          aria-controls={`${ids}-menu`}
          onClick={() => toggleMenu("sidebar")}
          className="relative flex min-h-11 w-full items-center gap-2.5 rounded-[10px] bg-white px-3 text-sm font-semibold text-slate-900 hover:bg-slate-50 aria-expanded:bg-slate-50"
        >
          <HelpIcon />
          <span className="truncate">{messages.help}</span>
        </button>
      </NeonFrame>
      {menuAnchor !== "header" ? menu("sidebar") : null}

      {/* The same Help in the mobile header, without opening the menu drawer. */}
      {headerSlot
        ? createPortal(
            <div ref={headerRoot} className="relative" onKeyDown={onMenuKeyDown} onBlur={onMenuBlur}>
              <NeonFrame intro={intro}>
                <button
                  ref={headerButton}
                  type="button"
                  aria-expanded={menuAnchor === "header"}
                  aria-controls={`${ids}-menu`}
                  aria-label={messages.help}
                  onClick={() => toggleMenu("header")}
                  className="relative flex min-h-11 items-center gap-2 rounded-[10px] bg-white px-3 text-sm font-semibold text-slate-900 hover:bg-slate-50 aria-expanded:bg-slate-50 max-[359px]:px-2.5"
                >
                  <HelpIcon />
                  <span aria-hidden="true" className="max-[359px]:hidden">{messages.help}</span>
                </button>
              </NeonFrame>
              {menuAnchor === "header" ? menu("header") : null}
            </div>,
            headerSlot
          )
        : null}

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
              auto={session.auto}
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
      className="fixed inset-0 m-auto open:flex max-h-[calc(100dvh-1.5rem)] w-[min(32rem,calc(100vw-1.5rem))] flex-col overflow-hidden rounded-2xl border border-slate-200 bg-white p-0 text-slate-900 shadow-(--th-shadow-float) backdrop:bg-(--th-scrim)"
    >
      <div className="min-h-0 flex-1 overflow-y-auto px-6 pb-2 pt-6 sm:px-8 sm:pt-8">
        <span aria-hidden="true" className="grid size-11 place-items-center rounded-xl border border-slate-200 bg-slate-50 text-blue-700">
          <svg className="size-6" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
            <circle cx="12" cy="12" r="9" />
            <path strokeLinejoin="round" d="M15.5 8.5l-2 5-5 2 2-5 5-2z" />
          </svg>
        </span>
        <h2 id={`${ids}-title`} className="mt-5 text-2xl font-semibold leading-tight tracking-tight text-slate-950">
          {messages.invite.title}
        </h2>
        <p id={`${ids}-body`} className="mt-2 text-[15px] leading-6 text-slate-700">
          {messages.invite.body}
        </p>
        <ol className="mt-5 grid gap-x-5 gap-y-2.5 rounded-xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-800 sm:grid-cols-2">
          {steps.map((step, index) => (
            <li key={step.id} className="flex items-start gap-2.5">
              <span aria-hidden="true" className="mt-px grid size-5 shrink-0 place-items-center rounded-full border border-slate-300 bg-white text-[11px] font-semibold tabular-nums text-slate-700">
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
          className="min-h-11 rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-blue-700"
        >
          {messages.invite.start}
        </button>
        <button
          type="button"
          onClick={onLater}
          className="min-h-11 rounded-lg border border-slate-300 bg-white px-5 py-2.5 text-sm font-semibold text-slate-800 hover:bg-slate-50"
        >
          {messages.invite.later}
        </button>
      </div>
    </dialog>
  )
}

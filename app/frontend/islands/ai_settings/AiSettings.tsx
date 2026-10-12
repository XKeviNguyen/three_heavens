import { useEffect, useId, useRef, useState, type FormEvent } from "react"

// Account → AI settings. The server is authoritative: every change is one
// request whose JSON response replaces the whole state, and each request
// carries the state token it was based on so a stale page cannot overwrite a
// change made elsewhere. The typed key lives only in this component's state
// until it is sent; it is never stored in the browser or shown again.

type PaymentSource = "managed" | "personal"
type DenialCode = "ai_account_ineligible" | "managed_ai_access_revoked" | "personal_key_unavailable"
type Field = "payment_source" | "api_key"

interface SettingsState {
  payment_source: PaymentSource
  managed_access: boolean
  personal_key: { configured: true; hint: string | null; added_at: string } | { configured: false }
  denial_code: DenialCode | null
  state_token: string
}

interface Messages {
  source_legend: string
  sources: {
    personal: { label: string; description: string; needs_key: string }
    managed: { label: string; description: string; enabled: string; disabled: string; badge: string }
  }
  save_source: string
  current: { ready_personal: string; ready_managed: string; blocked: string }
  key: {
    heading: string
    configured: string
    missing: string
    label: string
    hint: string
    save: string
    replace: string
    delete: string
    delete_confirm: string
    delete_confirm_personal: string
    replace_confirm: string
    cancel: string
  }
  setup: { heading: string; steps: [string, string, string]; step_done: string; step_current: string }
  // Denial texts worded for this page (the general ones point to AI settings).
  here: Partial<Record<DenialCode, string>>
  billing: { heading: string; items: string[] }
  working: string
  errors: Record<"network" | "session" | "unexpected", string>
}

export interface AiSettingsProps {
  state: SettingsState
  locale: string
  urls: { source: string; key: string }
  messages: Messages
  denials: Record<DenialCode, string>
}

interface Feedback {
  kind: "notice" | "error"
  text: string
  field: Field | null
}

interface MutationResponse {
  state?: SettingsState
  notice?: string
  error?: string
  field?: Field | null
}

function csrfToken(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

function interpolate(template: string, values: Record<string, string>): string {
  return template.replace(/%\{(\w+)\}/g, (match, name: string) => values[name] ?? match)
}

// Buttons are never disabled while a request runs: a disabled focused button
// drops keyboard focus to <body>. aria-disabled plus the in-flight guard keep
// focus in place and still prevent a second request.
const primaryButton =
  "min-h-11 rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 aria-disabled:cursor-not-allowed aria-disabled:bg-slate-400"

export function AiSettings({ state: initialState, locale, urls, messages, denials }: AiSettingsProps) {
  const [state, setState] = useState(initialState)
  const [selected, setSelected] = useState<PaymentSource>(initialState.payment_source)
  const [apiKey, setApiKey] = useState("")
  const [confirmingDelete, setConfirmingDelete] = useState(false)
  const [confirmingReplace, setConfirmingReplace] = useState(false)
  const [busy, setBusy] = useState(false)
  const [feedback, setFeedback] = useState<Feedback | null>(null)
  const inFlight = useRef(false)
  const ids = useId()
  const keyHeading = useRef<HTMLHeadingElement>(null)
  const deleteButton = useRef<HTMLButtonElement>(null)
  const cancelButton = useRef<HTMLButtonElement>(null)
  const keySubmit = useRef<HTMLButtonElement>(null)
  const replaceCancel = useRef<HTMLButtonElement>(null)
  // Focus to restore after the next render, when the focused control is replaced.
  const pendingFocus = useRef<HTMLElement | null | (() => HTMLElement | null)>(null)

  useEffect(() => {
    const target = pendingFocus.current
    pendingFocus.current = null
    const element = typeof target === "function" ? target() : target
    element?.focus()
  })

  function startDelete() {
    pendingFocus.current = () => cancelButton.current
    setConfirmingDelete(true)
  }

  function cancelDelete() {
    pendingFocus.current = () => deleteButton.current
    setConfirmingDelete(false)
  }

  async function mutate(method: "PATCH" | "PUT" | "DELETE", url: string, body: Record<string, unknown>) {
    // One request at a time: a double click never sends a second request
    // based on a state the first one is about to change.
    if (inFlight.current) return
    inFlight.current = true
    // Only a confirmation open when this request started belongs to it; one
    // opened while an unrelated request runs is left alone.
    const confirmedReplace = confirmingReplace
    const confirmedDelete = confirmingDelete
    setBusy(true)
    setFeedback(null)
    try {
      const response = await fetch(url, {
        method,
        credentials: "same-origin",
        // A signed-out session answers with a redirect to the sign-in page.
        redirect: "manual",
        headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
        body: JSON.stringify(body)
      })
      const isJson = (response.headers.get("Content-Type") ?? "").includes("application/json")
      if (response.type === "opaqueredirect" || !isJson) {
        const text = response.type === "opaqueredirect" ? messages.errors.session : messages.errors.unexpected
        setFeedback({ kind: "error", text, field: null })
        return
      }
      const payload = (await response.json()) as MutationResponse
      if (payload.state) {
        setState(payload.state)
        setSelected(payload.state.payment_source)
      }
      if (response.ok) {
        setApiKey("")
        if (confirmedDelete) pendingFocus.current = () => keyHeading.current
        else if (confirmedReplace) pendingFocus.current = () => keySubmit.current
        if (confirmedDelete) setConfirmingDelete(false)
        if (confirmedReplace) setConfirmingReplace(false)
        setFeedback({ kind: "notice", text: payload.notice ?? "", field: null })
      } else {
        // A refused replace or delete (stale page, invalid key) closes its
        // confirmation: the state may now show another key, which the user
        // has not confirmed.
        closeConfirmations(confirmedReplace, confirmedDelete)
        setFeedback({ kind: "error", text: payload.error ?? messages.errors.unexpected, field: payload.field ?? null })
      }
    } catch {
      closeConfirmations(confirmedReplace, confirmedDelete)
      setFeedback({ kind: "error", text: messages.errors.network, field: null })
    } finally {
      inFlight.current = false
      setBusy(false)
    }
  }

  function closeConfirmations(replace: boolean, remove: boolean) {
    if (replace) {
      pendingFocus.current = () => keySubmit.current
      setConfirmingReplace(false)
    }
    if (remove) {
      pendingFocus.current = () => deleteButton.current ?? keyHeading.current
      setConfirmingDelete(false)
    }
  }

  function submitSource(event: FormEvent) {
    event.preventDefault()
    if (selected === state.payment_source) return
    void mutate("PATCH", urls.source, { ai_settings: { payment_source: selected, state_token: state.state_token } })
  }

  // Replacing a saved key deletes the old one, so it is confirmed first, like
  // deleting. An empty field goes straight to the server, which explains it.
  function submitKey(event: FormEvent) {
    event.preventDefault()
    if (state.personal_key.configured && apiKey.trim() !== "" && !confirmingReplace) {
      pendingFocus.current = () => replaceCancel.current
      setConfirmingReplace(true)
      return
    }
    sendKey()
  }

  function sendKey() {
    void mutate("PUT", urls.key, { open_router_key: { api_key: apiKey, state_token: state.state_token } })
  }

  function cancelReplace() {
    pendingFocus.current = () => keySubmit.current
    setConfirmingReplace(false)
  }

  function deleteKey() {
    void mutate("DELETE", urls.key, { open_router_key: { state_token: state.state_token } })
  }

  const key = state.personal_key
  // UTC, like the server-rendered fallback, so the date does not change on mount.
  const addedOn = key.configured
    ? new Intl.DateTimeFormat(locale, { dateStyle: "long", timeZone: "UTC" }).format(new Date(key.added_at))
    : ""
  const hint = key.configured ? (key.hint ?? "") : ""
  const error = feedback?.kind === "error" ? feedback : null
  const sourceError = error?.field === "payment_source" ? error.text : null
  const keyError = error?.field === "api_key" ? error.text : null
  const generalError = error && !sourceError && !keyError ? error.text : null
  const notice = feedback?.kind === "notice" ? feedback.text : null
  const options: { source: PaymentSource; available: boolean; detail: string | null }[] = [
    { source: "personal", available: key.configured, detail: key.configured ? null : messages.sources.personal.needs_key },
    {
      source: "managed",
      available: state.managed_access,
      detail: state.managed_access ? messages.sources.managed.enabled : messages.sources.managed.disabled
    }
  ]
  // Add key → choose it → ready. Each step is done or not from the server's state.
  const setupDone = [key.configured, key.configured && state.payment_source === "personal", key.configured && state.payment_source === "personal" && !state.denial_code]
  const currentStep = setupDone.indexOf(false)
  const showSetup = !(state.payment_source === "managed" && !state.denial_code && !key.configured)

  return (
    <div className="space-y-6">
      <p
        className={`rounded-xl border p-4 text-sm leading-6 ${state.denial_code ? "border-amber-200 bg-amber-50 text-amber-950" : "border-emerald-200 bg-emerald-50 text-emerald-900"}`}
        data-testid="ai-settings-status"
        data-tour-target="ai-status"
      >
        {state.denial_code ? (
          <>
            <strong className="font-semibold">{messages.current.blocked}</strong> {messages.here[state.denial_code] ?? denials[state.denial_code] ?? ""}
          </>
        ) : state.payment_source === "personal" ? (
          messages.current.ready_personal
        ) : (
          messages.current.ready_managed
        )}
      </p>

      <div role="status" aria-live="polite" className="text-sm">
        {busy ? <p className="text-slate-600">{messages.working}</p> : null}
        {notice ? <p className="font-medium text-emerald-800">{notice}</p> : null}
      </div>
      {generalError ? (
        <p role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
          {generalError}
        </p>
      ) : null}

      {/* The own-key steps, unless the account is already ready on platform
          billing and has no key: then they are an option, not a to-do. */}
      {showSetup ? (
        <section className="rounded-xl border border-slate-200 bg-white p-5" aria-labelledby={`${ids}-setup-heading`} data-testid="ai-settings-setup">
          <h2 id={`${ids}-setup-heading`} className="text-sm font-semibold text-slate-950">
            {messages.setup.heading}
          </h2>
          <ol className="mt-3 grid gap-3 sm:grid-cols-3">
            {messages.setup.steps.map((label, step) => {
              const done = setupDone[step]
              const current = step === currentStep
              return (
                <li key={label} aria-current={current ? "step" : undefined} className="flex items-start gap-2.5 text-sm">
                  <span
                    aria-hidden="true"
                    className={`grid size-6 shrink-0 place-items-center rounded-full text-xs font-semibold ${done ? "bg-emerald-700 text-white" : current ? "bg-blue-600 text-white" : "border border-slate-300 text-slate-600"}`}
                  >
                    {done ? "✓" : step + 1}
                  </span>
                  <span className={done ? "text-slate-700" : current ? "font-semibold text-slate-950" : "text-slate-600"}>
                    {label}
                    <span className="sr-only">{done ? ` (${messages.setup.step_done})` : current ? ` (${messages.setup.step_current})` : ""}</span>
                  </span>
                </li>
              )
            })}
          </ol>
        </section>
      ) : null}

      <form onSubmit={submitSource} className="rounded-xl border border-slate-200 bg-white p-5" data-tour-target="ai-source" noValidate>
        <fieldset aria-describedby={sourceError ? `${ids}-source-error` : undefined}>
          <legend className="text-lg font-semibold text-slate-950">{messages.source_legend}</legend>
          {options.map(({ source, available, detail }) => {
            const unavailable = !available && state.payment_source !== source
            const checked = selected === source
            return (
              <label
                key={source}
                className={`mt-3 flex gap-3 rounded-xl border p-4 ${checked ? "border-blue-500 bg-blue-50" : "border-slate-200"} ${unavailable ? "cursor-not-allowed" : "cursor-pointer hover:border-blue-300"}`}
              >
                <input
                  type="radio"
                  name="payment_source"
                  value={source}
                  checked={checked}
                  disabled={unavailable}
                  onChange={() => setSelected(source)}
                  className="mt-1 size-4 shrink-0"
                />
                <span className="min-w-0">
                  <span className="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <span className={`font-medium ${unavailable ? "text-slate-600" : "text-slate-950"}`}>{messages.sources[source].label}</span>
                    {source === "managed" && !state.managed_access ? (
                      <span className="rounded-full border border-amber-200 bg-amber-50 px-2 py-0.5 text-xs font-semibold text-amber-950">
                        {messages.sources.managed.badge}
                      </span>
                    ) : null}
                  </span>
                  <span className="mt-0.5 block text-sm text-slate-600">{messages.sources[source].description}</span>
                  {detail ? (
                    <span className={`mt-1 block text-sm ${source === "personal" ? "font-medium text-blue-700" : "text-slate-600"}`}>{detail}</span>
                  ) : null}
                </span>
              </label>
            )
          })}
        </fieldset>
        {sourceError ? (
          <p id={`${ids}-source-error`} role="alert" className="mt-3 text-sm text-red-700">
            {sourceError}
          </p>
        ) : null}
        <button type="submit" aria-disabled={busy || selected === state.payment_source} className={`mt-5 ${primaryButton}`}>
          {messages.save_source}
        </button>
      </form>

      <section className="rounded-xl border border-slate-200 bg-white p-5" data-tour-target="ai-key" aria-labelledby={`${ids}-key-heading`}>
        <h2 id={`${ids}-key-heading`} ref={keyHeading} tabIndex={-1} className="text-lg font-semibold text-slate-950">
          {messages.key.heading}
        </h2>
        <p className="mt-1 text-sm text-slate-600" data-testid="ai-settings-key-status">
          {key.configured ? interpolate(messages.key.configured, { hint, date: addedOn }) : messages.key.missing}
        </p>
        <form onSubmit={submitKey} className="mt-4" noValidate>
          <label htmlFor={`${ids}-api-key`} className="block text-sm font-medium text-slate-800">
            {messages.key.label}
          </label>
          <input
            id={`${ids}-api-key`}
            type="password"
            name="api_key"
            autoComplete="off"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            // An API key is not a sign-in password. These are hints to password
            // managers not to offer saving or filling it; none can be enforced.
            data-1p-ignore=""
            data-lpignore="true"
            data-bwignore=""
            data-form-type="other"
            maxLength={256}
            value={apiKey}
            onChange={(event) => setApiKey(event.target.value)}
            aria-invalid={keyError ? true : undefined}
            aria-describedby={keyError ? `${ids}-key-hint ${ids}-key-error` : `${ids}-key-hint`}
            className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"
          />
          <p id={`${ids}-key-hint`} className="mt-1 text-xs text-slate-500">
            {messages.key.hint}
          </p>
          {keyError ? (
            <p id={`${ids}-key-error`} role="alert" className="mt-2 text-sm text-red-700">
              {keyError}
            </p>
          ) : null}
          {confirmingReplace ? (
            <div className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3" role="group" aria-labelledby={`${ids}-replace-prompt`}>
              <p id={`${ids}-replace-prompt`} className="text-sm text-amber-950">
                {interpolate(messages.key.replace_confirm, { hint })}
              </p>
              <div className="mt-3 flex flex-wrap gap-2">
                <button type="button" aria-disabled={busy} onClick={sendKey} className={primaryButton}>
                  {messages.key.replace}
                </button>
                <button
                  type="button"
                  ref={replaceCancel}
                  aria-disabled={busy}
                  onClick={() => busy || cancelReplace()}
                  className="min-h-11 rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50"
                >
                  {messages.key.cancel}
                </button>
              </div>
            </div>
          ) : (
            <button ref={keySubmit} type="submit" aria-disabled={busy} className={`mt-3 ${primaryButton}`}>
              {key.configured ? messages.key.replace : messages.key.save}
            </button>
          )}
        </form>
        {key.configured && !confirmingReplace ? (
          <div className="mt-3">
            {confirmingDelete ? (
              <div className="rounded-lg border border-red-200 bg-red-50 p-3" role="group" aria-labelledby={`${ids}-delete-prompt`}>
                <p id={`${ids}-delete-prompt`} className="text-sm text-red-900">
                  {interpolate(messages.key.delete_confirm, { hint })}
                  {state.payment_source === "personal" ? ` ${messages.key.delete_confirm_personal}` : ""}
                </p>
                <div className="mt-3 flex flex-wrap gap-2">
                  <button
                    type="button"
                    aria-disabled={busy}
                    onClick={deleteKey}
                    className="min-h-11 rounded-lg bg-red-700 px-4 py-2 text-sm font-semibold text-white hover:bg-red-800 aria-disabled:cursor-not-allowed aria-disabled:bg-slate-400"
                  >
                    {messages.key.delete}
                  </button>
                  <button
                    type="button"
                    ref={cancelButton}
                    aria-disabled={busy}
                    onClick={() => busy || cancelDelete()}
                    className="min-h-11 rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50"
                  >
                    {messages.key.cancel}
                  </button>
                </div>
              </div>
            ) : (
              <button
                type="button"
                ref={deleteButton}
                aria-disabled={busy}
                onClick={() => busy || startDelete()}
                className="min-h-11 rounded-lg border border-red-300 bg-white px-4 py-2 text-sm font-semibold text-red-700 hover:bg-red-50 aria-disabled:cursor-not-allowed"
              >
                {messages.key.delete}
              </button>
            )}
          </div>
        ) : null}
      </section>

      <section className="rounded-xl border border-slate-200 bg-white p-5" data-tour-target="ai-billing" aria-labelledby={`${ids}-billing-heading`}>
        <h2 id={`${ids}-billing-heading`} className="text-lg font-semibold text-slate-950">
          {messages.billing.heading}
        </h2>
        <ul className="mt-3 list-disc space-y-2 pl-5 text-sm text-slate-700">
          {messages.billing.items.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </section>
    </div>
  )
}

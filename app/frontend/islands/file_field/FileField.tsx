import { useEffect, useId, useRef, useState, type DragEvent } from "react"

// One file input inside a Rails form. The input keeps its Rails name, so the
// form's normal multipart submission sends the file; this component only
// improves choosing, replacing, and clearing it. It never submits the form.
// The checks here mirror the server's limits for faster feedback; the server
// still validates every upload.

interface Messages {
  choose: string
  replace: string
  remove: string
  remove_named: string
  drop: string
  none: string
  help: string
  selected: string
  removed: string
  unsupported: string
  too_large: string
  multiple: string
  both: string
}

interface FileFieldProps {
  id: string
  name: string
  label: string
  accept: string
  extensions: string[]
  maxBytes: number
  locale: string
  pairedTextId: string | null
  messages: Messages
}

const MESSAGE_KEYS: (keyof Messages)[] = [
  "choose", "replace", "remove", "remove_named", "drop", "none", "help", "selected", "removed", "unsupported", "too_large", "multiple", "both"
]

function parseProps(raw: Record<string, unknown>): FileFieldProps | null {
  const { id, name, label, accept, extensions, maxBytes, locale, pairedTextId, messages } = raw
  const strings = [id, name, label, accept, locale]
  if (!strings.every((value) => typeof value === "string" && value !== "")) return null
  if (!Array.isArray(extensions) || !extensions.every((value) => typeof value === "string")) return null
  if (typeof maxBytes !== "number" || maxBytes <= 0) return null
  if (pairedTextId !== null && typeof pairedTextId !== "string") return null
  if (messages === null || typeof messages !== "object") return null
  const record = messages as Record<string, unknown>
  if (!MESSAGE_KEYS.every((key) => typeof record[key] === "string")) return null
  return raw as unknown as FileFieldProps
}

function interpolate(template: string, values: Record<string, string>): string {
  return template.replace(/%\{(\w+)\}/g, (match, key: string) => values[key] ?? match)
}

function humanSize(bytes: number, locale: string): string {
  const units = ["B", "KB", "MB"] as const
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit += 1
  }
  const number = new Intl.NumberFormat(locale, { maximumFractionDigits: unit === 0 ? 0 : 1 }).format(value)
  return `${number} ${units[unit]}`
}

function extensionOf(filename: string): string {
  const dot = filename.lastIndexOf(".")
  return dot > 0 ? filename.slice(dot + 1).toLowerCase() : ""
}

export function FileField(rawProps: Record<string, unknown>) {
  const [props] = useState(() => parseProps(rawProps))
  if (!props) {
    console.error("File field props are invalid; keeping the browser's file input.")
    return null
  }
  return <FileFieldControl {...props} />
}

function FileFieldControl({ id, name, label, accept, extensions, maxBytes, locale, pairedTextId, messages }: FileFieldProps) {
  const [file, setFile] = useState<File | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [status, setStatus] = useState("")
  const [dragging, setDragging] = useState(false)
  const [pairedHasText, setPairedHasText] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const chooseRef = useRef<HTMLButtonElement>(null)
  const ids = useId()

  // The paired text area belongs to the Rails form; this only reads it to
  // warn early that the server accepts pasted text or a file, not both.
  useEffect(() => {
    const field = pairedTextId ? document.getElementById(pairedTextId) : null
    if (!(field instanceof HTMLTextAreaElement)) return
    const update = () => setPairedHasText(field.value.trim() !== "")
    update()
    field.addEventListener("input", update)
    return () => field.removeEventListener("input", update)
  }, [pairedTextId])

  // Puts the input back to the last accepted file after a rejected choice.
  function restoreInput(previous: File | null) {
    const input = inputRef.current
    if (!input) return
    if (previous) {
      const transfer = new DataTransfer()
      transfer.items.add(previous)
      input.files = transfer.files
    } else {
      input.value = ""
    }
  }

  function reject(message: string) {
    restoreInput(file)
    setError(message)
    // A repeat of the same rejection must still change the live region.
    setStatus((previous) => (previous === message ? `${message}\u00a0` : message))
  }

  function takeFiles(files: FileList | null, fromDrop: boolean) {
    // An empty list is a cancelled picker; keep the current file.
    if (!files || files.length === 0) {
      restoreInput(file)
      return
    }
    if (files.length > 1) return reject(messages.multiple)
    const candidate = files[0]!
    if (!extensions.includes(extensionOf(candidate.name))) return reject(interpolate(messages.unsupported, { name: candidate.name }))
    if (candidate.size > maxBytes) return reject(interpolate(messages.too_large, { name: candidate.name }))

    if (fromDrop && inputRef.current) inputRef.current.files = files
    setFile(candidate)
    setError(null)
    setStatus(interpolate(messages.selected, { name: candidate.name, size: humanSize(candidate.size, locale) }))
  }

  function clear() {
    restoreInput(null)
    setFile(null)
    setError(null)
    setStatus(messages.removed)
    chooseRef.current?.focus()
  }

  const carriesFiles = (event: DragEvent) => Array.from(event.dataTransfer.types).includes("Files")

  function onDragOver(event: DragEvent) {
    // Only files can be dropped here; dragged text keeps the browser default.
    if (!carriesFiles(event)) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
    setDragging(true)
  }

  function onDragLeave(event: DragEvent) {
    const next = event.relatedTarget
    if (next instanceof Node && event.currentTarget.contains(next)) return
    setDragging(false)
  }

  function onDrop(event: DragEvent) {
    if (!carriesFiles(event)) return
    event.preventDefault()
    setDragging(false)
    takeFiles(event.dataTransfer.files, true)
  }

  const describedBy = [`${ids}-help`, error ? `${ids}-error` : null, file && pairedHasText ? `${ids}-both` : null].filter(Boolean).join(" ")

  return (
    <div className="mt-4">
      <label htmlFor={id} id={`${ids}-label`} className="block text-sm font-medium text-slate-700">
        {label}
      </label>
      <div
        data-testid="file-field"
        onDragOver={onDragOver}
        onDragEnter={onDragOver}
        onDragLeave={onDragLeave}
        onDrop={onDrop}
        className={`mt-2 rounded-xl border border-dashed p-4 ${dragging ? "border-blue-500 bg-blue-50" : error ? "border-red-300 bg-white" : "border-slate-300 bg-slate-50"}`}
      >
        {/* The real input: submitted with the form, operated through the button. */}
        <input
          ref={inputRef}
          type="file"
          id={id}
          name={name}
          accept={accept}
          tabIndex={-1}
          aria-hidden="true"
          className="sr-only"
          onChange={(event) => takeFiles(event.currentTarget.files, false)}
        />
        <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
          <button
            ref={chooseRef}
            id={`${ids}-choose`}
            type="button"
            onClick={() => inputRef.current?.click()}
            aria-labelledby={`${ids}-label ${ids}-choose`}
            aria-describedby={describedBy}
            className="min-h-11 rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 shadow-sm hover:bg-slate-50"
          >
            {file ? messages.replace : messages.choose}
          </button>
          <span className="text-sm text-slate-600">{messages.drop}</span>
        </div>

        {file ? (
          <div className="mt-3 flex min-w-0 items-center gap-3 rounded-lg bg-white p-3 ring-1 ring-slate-200" data-testid="file-field-selection">
            <svg className="size-5 shrink-0 text-slate-500" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
              <path strokeLinejoin="round" d="M5.5 2.5h6l3 3v12h-9z" />
              <path strokeLinejoin="round" d="M11.5 2.5v3h3" />
            </svg>
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-slate-950" title={file.name}>
                {file.name}
              </p>
              <p className="text-xs text-slate-500">{humanSize(file.size, locale)}</p>
            </div>
            <button
              type="button"
              onClick={clear}
              aria-label={interpolate(messages.remove_named, { name: file.name })}
              className="min-h-11 shrink-0 rounded-lg px-3 py-2 text-sm font-semibold text-red-700 hover:bg-red-50"
            >
              {messages.remove}
            </button>
          </div>
        ) : (
          <p className="mt-3 text-sm text-slate-500">{messages.none}</p>
        )}

        <p id={`${ids}-help`} className="mt-2 text-xs text-slate-500">
          {messages.help}
        </p>
        {error ? (
          <p id={`${ids}-error`} className="mt-2 text-sm font-medium text-red-700">
            {error}
          </p>
        ) : null}
        {file && pairedHasText ? (
          <p id={`${ids}-both`} className="mt-2 text-sm text-amber-800">
            {messages.both}
          </p>
        ) : null}
        <p role="status" aria-live="polite" className="sr-only">
          {status}
        </p>
      </div>
    </div>
  )
}

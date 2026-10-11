import { StrictMode, type ComponentType } from "react"
import { createRoot, type Root } from "react-dom/client"

// Reusable island adapter. Server markup:
//   <div data-react-island="NAME" data-react-props='{"json":true}'>fallback</div>
// React owns only the container subtree; everything else stays with Turbo/Stimulus.

type IslandComponent = ComponentType<any>

interface MountedIsland {
  root: Root
  fallback: Node[]
}

// State lives on window so a re-evaluated module shares one registry, one
// mounted set and one set of document listeners (no duplicate roots).
interface IslandState {
  registry: Map<string, IslandComponent>
  mounted: Map<HTMLElement, MountedIsland>
  listening: boolean
}

declare global {
  interface Window {
    ThreeHeavensIslands?: { mountedCount(): number }
    __threeHeavensIslandState?: IslandState
  }
}

const state: IslandState = (window.__threeHeavensIslandState ??= {
  registry: new Map(),
  mounted: new Map(),
  listening: false
})
const { registry, mounted } = state

export function registerIsland<P extends object>(name: string, component: ComponentType<P>): void {
  registry.set(name, component as IslandComponent)
}

function parseProps(raw: string | undefined): Record<string, unknown> | null {
  if (raw === undefined || raw === "") return {}
  try {
    const parsed: unknown = JSON.parse(raw)
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>
    }
  } catch {
    // Fall through; never echo the props, they may be sensitive.
  }
  return null
}

function mountContainer(container: HTMLElement): void {
  if (mounted.has(container)) return

  const name = container.dataset.reactIsland ?? ""
  const component = registry.get(name)
  if (!component) {
    console.error(`React island "${name}" is not registered; keeping the server-rendered fallback.`)
    return
  }
  const props = parseProps(container.dataset.reactProps)
  if (props === null) {
    console.error(`React island "${name}" has invalid props JSON; keeping the server-rendered fallback.`)
    return
  }

  const fallback = Array.from(container.childNodes, (node) => node.cloneNode(true))
  // A render error must not leave an empty container: put the working
  // server-rendered fallback back (after React finishes its own teardown).
  const root = createRoot(container, {
    onUncaughtError: (error) => {
      console.error(`React island "${name}" failed; restoring the server-rendered fallback.`, error)
      window.setTimeout(() => unmountContainer(container, true), 0)
    }
  })
  mounted.set(container, { root, fallback })
  container.dataset.reactMounted = "true"
  const Component = component
  root.render(
    <StrictMode>
      <Component {...props} />
    </StrictMode>
  )
}

function unmountContainer(container: HTMLElement, restoreFallback: boolean): void {
  const entry = mounted.get(container)
  if (!entry) return
  mounted.delete(container)
  entry.root.unmount()
  delete container.dataset.reactMounted
  if (restoreFallback) container.replaceChildren(...entry.fallback)
}

function sweepDisconnected(): void {
  for (const container of Array.from(mounted.keys())) {
    if (!container.isConnected) unmountContainer(container, false)
  }
}

function mountAll(): void {
  sweepDisconnected()
  document.querySelectorAll<HTMLElement>("[data-react-island]").forEach(mountContainer)
}

function unmountAllForCache(): void {
  for (const container of Array.from(mounted.keys())) unmountContainer(container, true)
}

function unmountOutside(newBody: Node | undefined): void {
  for (const container of Array.from(mounted.keys())) {
    if (!newBody || !newBody.contains(container)) unmountContainer(container, false)
  }
}

export function startIslands(): void {
  if (!state.listening) {
    state.listening = true
    document.addEventListener("turbo:load", mountAll)
    document.addEventListener("turbo:frame-load", mountAll)
    document.addEventListener("turbo:before-cache", unmountAllForCache)
    document.addEventListener("turbo:before-render", (event) => {
      const detail = (event as CustomEvent<{ newBody?: Node }>).detail
      unmountOutside(detail?.newBody)
    })
    window.ThreeHeavensIslands = { mountedCount: () => mounted.size }
  }

  // The script can be evaluated after turbo:load already fired (Turbo inserts
  // new head scripts during a visit) or on a page without Turbo.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mountAll, { once: true })
  } else {
    mountAll()
  }
}

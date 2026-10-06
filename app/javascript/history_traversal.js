// Turbo answers popstate by starting a restore visit at once, and that visit
// moves Turbo's history position, merges the destination head, and records
// the snapshot location before any render hook can object. Chrome runs
// window listeners in registration order even when one captures, so this
// module is imported before Turbo starts: a page that must save before
// leaving cancels "history:traverse" and Turbo never sees the traversal,
// leaving its navigation state on the current page.
window.addEventListener("popstate", event => {
  const traversal = new CustomEvent("history:traverse", { cancelable: true })
  if (!window.dispatchEvent(traversal)) event.stopImmediatePropagation()
}, true)

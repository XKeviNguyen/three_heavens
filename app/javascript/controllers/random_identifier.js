// Random lowercase hex identifiers for editor and request identity. They are
// held in memory only and never carry user content.
export function randomHex(bytes) {
  return Array.from(window.crypto.getRandomValues(new Uint8Array(bytes)), byte => byte.toString(16).padStart(2, "0")).join("")
}

/** Optional per-transfer cancellation, including a stalled response with no data callback. */
export class DownloadCancellation {
  private cancelled: boolean = false
  private listeners: Set<() => void> = new Set<() => void>()

  isCancelled(): boolean { return this.cancelled }

  subscribe(listener: () => void): () => void {
    if (this.cancelled) { listener(); return (): void => {} }
    this.listeners.add(listener)
    return (): void => { this.listeners.delete(listener) }
  }

  cancel(): void {
    if (this.cancelled) { return }
    this.cancelled = true
    const pending = Array.from(this.listeners)
    this.listeners.clear()
    for (const listener of pending) { listener() }
  }
}

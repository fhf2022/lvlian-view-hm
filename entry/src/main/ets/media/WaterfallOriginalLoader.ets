import { FileEntry } from '../model/FileEntry'
import { DownloadCancellation } from '../core/network/DownloadCancellation'

export interface WaterfallLoadRange {
  start: number
  end: number
  groupSize: number
}

/** Load groups are not WaterFlow sections: item identities and layout stay intact. */
export function waterfallLoadRange(first: number, last: number, count: number): WaterfallLoadRange {
  if (count <= 0) { return { start: 0, end: -1, groupSize: 12 } }
  const start = Math.max(0, Math.min(count - 1, Math.floor(first)))
  const end = Math.max(start, Math.min(count - 1, Math.floor(last)))
  let size = 12
  // Very short panoramas can expose more than 36 items. Cover all visible
  // items with three larger groups rather than leave visible placeholders.
  while (Math.floor(end / size) - Math.floor(start / size) > 2) { size *= 2 }
  const lastGroup = Math.floor((count - 1) / size)
  const middle = Math.floor((start + end) / 2 / size)
  const firstGroup = Math.max(0, Math.min(middle - 1, lastGroup - 2, Math.floor(start / size)))
  return { start: firstGroup * size, end: Math.min(count - 1, (firstGroup + 3) * size - 1), groupSize: size }
}

export interface WaterfallOriginalDelegate {
  fileKey: (entry: FileEntry) => string
  download: (entry: FileEntry, valid: () => boolean, cancellation: DownloadCancellation) => Promise<string>
  ready: (entry: FileEntry, path: string, valid: () => boolean) => Promise<void>
}

class OriginalRequest {
  key: string
  entry: FileEntry
  session: number
  cancellation: DownloadCancellation = new DownloadCancellation()
  promise: Promise<void> = Promise.resolve()
  constructor(entry: FileEntry, key: string, session: number) {
    this.entry = entry.clone(); this.key = key; this.session = session
  }
}

/** At most two physical writers, including cancelled jobs still closing an FD. */
export class WaterfallOriginalLoader {
  private session: number = 0
  private paused: boolean = false
  private limit: number = 2
  private targets: FileEntry[] = []
  private wanted: Set<string> = new Set<string>()
  private completed: Set<string> = new Set<string>()
  private failed: Set<string> = new Set<string>()
  private active: Map<string, OriginalRequest> = new Map<string, OriginalRequest>()
  private delegate: WaterfallOriginalDelegate

  constructor(delegate: WaterfallOriginalDelegate) { this.delegate = delegate }

  update(entries: FileEntry[], first: number, last: number, paused: boolean, limit: number = 2): void {
    const range = waterfallLoadRange(first, last, entries.length)
    const wanted: Set<string> = new Set<string>()
    const targets: FileEntry[] = []
    const visibleFirst = Math.max(range.start, Math.min(range.end, first))
    const visibleLast = Math.max(visibleFirst, Math.min(range.end, last))
    // Visible originals take priority over neighbouring groups.
    for (let index = visibleFirst; index <= visibleLast; index++) { if (entries[index] !== undefined) { targets.push(entries[index]) } }
    for (let index = visibleLast + 1; index <= range.end; index++) { targets.push(entries[index]) }
    for (let index = visibleFirst - 1; index >= range.start; index--) { targets.push(entries[index]) }
    for (const entry of targets) { wanted.add(this.delegate.fileKey(entry)) }
    const changed = wanted.size !== this.wanted.size || targets.some(
      (entry: FileEntry): boolean => !this.wanted.has(this.delegate.fileKey(entry)))
    if (changed || (this.paused && !paused)) { this.failed.clear() }
    this.targets = targets; this.wanted = wanted; this.paused = paused
    this.limit = Math.max(1, Math.min(2, limit))
    this.completed.forEach((key: string): void => { if (!wanted.has(key)) { this.completed.delete(key) } })
    this.active.forEach((request: OriginalRequest): void => {
      if (!this.valid(request)) { request.cancellation.cancel() }
    })
    this.pump()
  }

  pause(): void { this.paused = true }

  invalidate(entry: FileEntry): void {
    const key = this.delegate.fileKey(entry)
    this.completed.delete(key); this.failed.delete(key)
  }

  reset(): void {
    this.session++; this.targets = []; this.wanted.clear(); this.completed.clear(); this.failed.clear()
    this.active.forEach((request: OriginalRequest): void => request.cancellation.cancel())
  }

  /** Viewer promotion must wait for this writer to finish, then reuse its disk file. */
  async settle(entry: FileEntry): Promise<void> {
    const request = this.active.get(this.delegate.fileKey(entry))
    if (request !== undefined) { await request.promise }
  }

  private valid(request: OriginalRequest): boolean {
    return request.session === this.session && !request.cancellation.isCancelled() &&
      this.wanted.has(request.key) && this.delegate.fileKey(request.entry) === request.key
  }

  private pump(): void {
    if (this.paused) { return }
    for (const entry of this.targets) {
      if (this.active.size >= this.limit) { break }
      const key = this.delegate.fileKey(entry)
      if (this.active.has(key) || this.completed.has(key) || this.failed.has(key)) { continue }
      const request = new OriginalRequest(entry, key, this.session)
      this.active.set(key, request)
      request.promise = this.run(request)
    }
  }

  private async run(request: OriginalRequest): Promise<void> {
    const valid = (): boolean => this.valid(request)
    try {
      const path = await this.delegate.download(request.entry, valid, request.cancellation)
      if (!valid()) { return }
      if (path.length === 0) { this.failed.add(request.key); return }
      this.completed.add(request.key)
      await this.delegate.ready(request.entry, path, valid)
    } catch (_) {
      if (valid()) { this.failed.add(request.key) }
    } finally {
      this.active.delete(request.key)
      this.pump()
    }
  }
}

import { FileEntry } from '../model/FileEntry'
import { DownloadCancellation } from '../core/network/DownloadCancellation'

export interface WaterfallOriginalDelegate {
  fileKey: (entry: FileEntry) => string
  download: (entry: FileEntry, valid: () => boolean, cancellation: DownloadCancellation) => Promise<string>
  ready: (entry: FileEntry, path: string, valid: () => boolean) => Promise<void>
  finished: (entry: FileEntry, success: boolean, error?: Object) => void
}

class OriginalRequest {
  key: string
  entry: FileEntry
  session: number
  cancellation: DownloadCancellation = new DownloadCancellation()
  running: boolean = false
  complete: boolean = false
  failed: boolean = false
  promise: Promise<string>
  resolve: (path: string) => void = (): void => {}
  reject: (error: Object) => void = (): void => {}
  constructor(entry: FileEntry, key: string, session: number) {
    this.entry = entry.clone(); this.key = key; this.session = session
    this.promise = new Promise<string>((resolve, reject) => { this.resolve = resolve; this.reject = reject })
    this.promise.catch((): void => {})
  }
}

/** One promise for every queued/running group member. Viewer borrows that promise;
 * its cancellation does not interrupt the group. Only physical cleanup frees a slot. */
export class WaterfallOriginalLoader {
  private session: number = 0
  private limit: number = 2
  private active: number = 0
  private targets: FileEntry[] = []
  private wanted: Set<string> = new Set<string>()
  private requests: Map<string, OriginalRequest> = new Map<string, OriginalRequest>()
  private delegate: WaterfallOriginalDelegate
  private preparation: (() => Promise<void>)[] = []

  constructor(delegate: WaterfallOriginalDelegate) { this.delegate = delegate }

  // Rare formats requiring a full original for geometry share the exact
  // same physical slots as ordinary group downloads.
  runPreparation<T>(operation: () => Promise<T>, cancellation: DownloadCancellation, limit: number = 2): Promise<T> {
    this.limit = Math.max(1, Math.min(2, limit))
    return new Promise<T>((resolve, reject) => {
      const unsubscribe = cancellation.subscribe((): void => reject(new Error('Geometry cancelled')))
      this.preparation.push(async (): Promise<void> => {
        try {
          if (cancellation.isCancelled()) { throw new Error('Geometry cancelled') }
          resolve(await operation())
        } catch (error) { reject(error as Object) } finally { unsubscribe() }
      })
      this.pump()
    })
  }

  update(entries: FileEntry[], limit: number = 2): void {
    this.limit = Math.max(1, Math.min(2, limit))
    this.targets = entries
    this.wanted = new Set<string>(entries.map((entry: FileEntry): string => this.delegate.fileKey(entry)))
    this.requests.forEach((request: OriginalRequest): void => {
      if (!this.valid(request)) {
        request.cancellation.cancel()
        if (!request.running) { this.requests.delete(request.key); request.reject(new Error('Original group cancelled')) }
      }
    })
    for (const entry of entries) { this.request(entry) }
    this.pump()
  }

  requestMember(entry: FileEntry): Promise<string> | null {
    const key = this.delegate.fileKey(entry)
    if (!this.wanted.has(key)) { return null }
    const old = this.requests.get(key)
    if (old !== undefined && old.failed && !old.running) { this.requests.delete(key) }
    const request = this.request(entry)
    // Promote a selected queued member, preserving active downloads.
    this.targets = [entry].concat(this.targets.filter((item: FileEntry): boolean => this.delegate.fileKey(item) !== key))
    this.pump()
    return request.promise
  }

  invalidate(entry: FileEntry): void {
    const request = this.requests.get(this.delegate.fileKey(entry))
    if (request !== undefined && !request.running) { this.requests.delete(request.key) }
  }

  retryFailed(): void {
    this.requests.forEach((request: OriginalRequest): void => {
      if (request.failed && !request.running) { this.requests.delete(request.key) }
    })
  }

  reset(): void {
    this.session++; this.targets = []; this.wanted.clear()
    this.requests.forEach((request: OriginalRequest): void => {
      request.cancellation.cancel()
      if (!request.running) { this.requests.delete(request.key); request.reject(new Error('Original group cancelled')) }
    })
  }

  private request(entry: FileEntry): OriginalRequest {
    const key = this.delegate.fileKey(entry)
    const old = this.requests.get(key)
    if (old !== undefined) { return old }
    const request = new OriginalRequest(entry, key, this.session)
    this.requests.set(key, request)
    return request
  }

  private valid(request: OriginalRequest): boolean {
    return request.session === this.session && !request.cancellation.isCancelled() &&
      this.wanted.has(request.key) && this.delegate.fileKey(request.entry) === request.key
  }

  private pump(): void {
    while (this.active < this.limit && this.preparation.length > 0) {
      const work = this.preparation.shift()
      if (work === undefined) { break }
      this.active++
      work().finally((): void => { this.active--; this.pump() })
    }
    for (const entry of this.targets) {
      if (this.active >= this.limit) { break }
      const request = this.request(entry)
      if (!this.valid(request) || request.running || request.complete || request.failed) { continue }
      request.running = true; this.active++
      this.run(request)
    }
  }

  private async run(request: OriginalRequest): Promise<void> {
    const valid = (): boolean => this.valid(request)
    try {
      const path = await this.delegate.download(request.entry, valid, request.cancellation)
      if (!valid() || path.length === 0) { throw new Error('Original unavailable') }
      await this.delegate.ready(request.entry, path, valid)
      if (!valid()) { throw new Error('Original group cancelled') }
      request.complete = true
      request.resolve(path)
      this.delegate.finished(request.entry, true)
    } catch (error) {
      request.failed = true; request.reject(error as Object)
      if (valid()) { this.delegate.finished(request.entry, false, error as Object) }
    } finally {
      request.running = false; this.active = Math.max(0, this.active - 1)
      if (!valid() && this.requests.get(request.key) === request) { this.requests.delete(request.key) }
      this.pump()
    }
  }
}

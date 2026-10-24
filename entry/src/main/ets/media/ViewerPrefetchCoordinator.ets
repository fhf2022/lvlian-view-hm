import { hilog } from '@kit.PerformanceAnalysisKit'
import { FileEntry } from '../model/FileEntry'
import { BinaryDownloadProgress, BinaryProgressListener } from '../core/network/HttpTransport'
import { DownloadCancellation } from '../core/network/DownloadCancellation'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'

const PREFETCH_DOMAIN: number = 0xD003
const PREFETCH_TAG: string = 'ViewerPrefetch'
const PREFETCH_DISTANCE: number = 2

export enum ViewerEntryState {
  NONE = 'none',
  PREVIEW_READY = 'preview_ready',
  ORIGINAL_FILE_READY = 'original_file_ready',
  ORIGINAL_PIXELMAP_READY = 'original_pixelmap_ready'
}

export interface ViewerPrefetchDelegate {
  isViewerActive: () => boolean
  isInteractionBusy: () => boolean
  shouldAutoPrefetch: () => boolean
  maxConcurrentDownloads: () => number
  fileKey: (entry: FileEntry) => string
  isFileCached: (entry: FileEntry) => boolean
  downloadOriginalFile: (entry: FileEntry, onProgress: BinaryProgressListener,
    shouldContinue: () => boolean, cancellation: DownloadCancellation) => Promise<string>
  onOriginalFileReady: (entry: FileEntry, localPath: string) => Promise<void>
}

class ViewerFileRequest {
  entry: FileEntry
  key: string
  session: number
  manual: boolean = false
  running: boolean = false
  cancellation: DownloadCancellation = new DownloadCancellation()
  progress: BinaryProgressListener | undefined = undefined
  promise: Promise<string>
  resolve: (path: string) => void = (_path: string): void => {}
  reject: (error: Object) => void = (_error: Object): void => {}

  constructor(entry: FileEntry, key: string, session: number) {
    this.entry = entry.clone()
    this.key = key
    this.session = session
    this.promise = new Promise<string>((resolve, reject) => {
      this.resolve = resolve
      this.reject = reject
    })
    // Queued prefetch has no UI waiter. Cancellation must still be handled.
    this.promise.catch((): void => {})
  }
}

/** One bounded file-download owner for the current page and its next two pages.
 * Neighbours are compressed files on disk only; PixelMap decoding stays in Index.
 */
export class ViewerPrefetchCoordinator {
  private currentIndex: number = -1
  private direction: number = 1
  private session: number = 0
  private idleTimerId: number = -1
  private prefetchReady: boolean = false
  private activeCount: number = 0
  private requests: Map<string, ViewerFileRequest> = new Map<string, ViewerFileRequest>()
  private failed: Set<string> = new Set<string>()
  private entryStates: Map<string, ViewerEntryState> = new Map<string, ViewerEntryState>()
  private images: FileEntry[] = []
  private delegate: ViewerPrefetchDelegate

  constructor(delegate: ViewerPrefetchDelegate) { this.delegate = delegate }

  getEntryState(path: string): ViewerEntryState {
    return this.entryStates.get(path) ?? ViewerEntryState.NONE
  }

  onViewerOpened(initialIndex: number, images: FileEntry[]): void {
    this.onViewerClosed()
    this.currentIndex = initialIndex
    this.direction = 1
    this.images = images
    hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG,
      `[Coordinator] opened index=${initialIndex} count=${images.length} distance=2`)
  }

  onViewerIndexChanged(newIndex: number, images: FileEntry[]): void {
    this.disarmIdleGate()
    const previousIndex = this.currentIndex
    if (previousIndex >= 0 && newIndex !== previousIndex) {
      this.direction = newIndex > previousIndex ? 1 : -1
    }
    this.currentIndex = newIndex
    this.images = images
    this.failed.clear()
    this.entryStates.forEach((_state: ViewerEntryState, path: string): void => {
      if (path !== this.currentEntry()?.path) { this.entryStates.delete(path) }
    })
    // Keep an in-flight neighbour when it becomes current. Cancel only files
    // outside the new directional window, never reset occupied slots early.
    this.pruneRequests()
    hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG,
      `[Coordinator] indexChanged from=${previousIndex} to=${newIndex} dir=${this.direction}`)
  }

  onCurrentOriginalRevealed(path: string): void {
    if (path !== this.currentEntry()?.path) { return }
    this.entryStates.set(path, ViewerEntryState.ORIGINAL_PIXELMAP_READY)
    this.armIdleGate()
  }

  onUserInteraction(): void { this.disarmIdleGate() }

  onInteractionEnded(): void {
    if (this.getEntryState(this.currentEntry()?.path ?? '') === ViewerEntryState.ORIGINAL_PIXELMAP_READY) {
      this.armIdleGate()
    }
  }

  armIdleGate(delayMs: number = 200): void {
    this.disarmIdleGate()
    if (!this.canPrefetch()) { return }
    const session = this.session
    this.idleTimerId = setTimeout((): void => {
      this.idleTimerId = -1
      if (session !== this.session || !this.canPrefetch()) { return }
      this.prefetchReady = true
      this.pump()
    }, delayMs)
  }

  disarmIdleGate(): void {
    this.prefetchReady = false
    if (this.idleTimerId !== -1) { clearTimeout(this.idleTimerId); this.idleTimerId = -1 }
  }

  onViewerClosed(): void {
    this.disarmIdleGate()
    this.session++
    this.currentIndex = -1
    this.images = []
    this.entryStates.clear()
    this.failed.clear()
    this.pruneRequests()
  }

  /** Promote an existing prefetch instead of opening the same .part twice. */
  async downloadCurrentOriginal(entry: FileEntry, onProgress: BinaryProgressListener,
    manual: boolean): Promise<string> {
    const key = this.delegate.fileKey(entry)
    if (key !== this.currentKey() || !this.delegate.isViewerActive()) { throw this.cancelled() }
    const existing = this.requests.get(key)
    if (existing !== undefined && (existing.session !== this.session || existing.cancellation.isCancelled())) {
      // An old session may still be closing its file descriptor. Its finally
      // must release ownership before another writer can use this same path.
      try { await existing.promise } catch (_) {}
      return await this.downloadCurrentOriginal(entry, onProgress, manual)
    }
    const request = existing ?? this.enqueue(entry)
    request.manual = request.manual || manual
    request.progress = onProgress
    this.failed.delete(key)
    this.pump()
    return await request.promise
  }

  private currentEntry(): FileEntry | undefined { return this.images[this.currentIndex] }
  private currentKey(): string {
    const entry = this.currentEntry()
    return entry === undefined ? '' : this.delegate.fileKey(entry)
  }
  private cancelled(): UgreenError {
    return new UgreenError(UgreenErrorKind.NETWORK, '原图加载已取消', 499)
  }
  private canPrefetch(): boolean {
    return this.delegate.isViewerActive() && !this.delegate.isInteractionBusy() &&
      this.delegate.shouldAutoPrefetch()
  }
  private targets(): FileEntry[] {
    const targets: FileEntry[] = []
    if (this.currentEntry() === undefined) { return targets }
    for (let distance = 1; distance <= PREFETCH_DISTANCE; distance++) {
      const entry = this.images[this.currentIndex + distance * this.direction]
      if (entry !== undefined) { targets.push(entry) }
    }
    return targets
  }
  private wanted(request: ViewerFileRequest): boolean {
    if (request.session !== this.session || request.cancellation.isCancelled() ||
      !this.delegate.isViewerActive()) { return false }
    if (request.key === this.currentKey()) { return request.manual || this.delegate.shouldAutoPrefetch() }
    return this.delegate.shouldAutoPrefetch() && this.targets().some(
      (entry: FileEntry): boolean => this.delegate.fileKey(entry) === request.key)
  }
  private pruneRequests(): void {
    this.requests.forEach((request: ViewerFileRequest, key: string): void => {
      if (this.wanted(request)) { return }
      request.cancellation.cancel()
      if (!request.running) {
        this.requests.delete(key)
        request.reject(this.cancelled())
      }
    })
  }
  private enqueue(entry: FileEntry): ViewerFileRequest {
    const request = new ViewerFileRequest(entry, this.delegate.fileKey(entry), this.session)
    this.requests.set(request.key, request)
    return request
  }
  private notifyReady(request: ViewerFileRequest, localPath: string): void {
    if (!this.wanted(request)) { return }
    if (this.getEntryState(request.entry.path) !== ViewerEntryState.ORIGINAL_PIXELMAP_READY) {
      this.entryStates.set(request.entry.path, ViewerEntryState.ORIGINAL_FILE_READY)
    }
    if (!this.delegate.isInteractionBusy()) {
      this.delegate.onOriginalFileReady(request.entry, localPath).catch((): void => {})
    }
  }
  private pump(): void {
    this.pruneRequests()
    const limit = Math.max(1, Math.min(2, this.delegate.maxConcurrentDownloads()))
    if (this.prefetchReady && this.canPrefetch()) {
      for (const entry of this.targets()) {
        const key = this.delegate.fileKey(entry)
        if (this.requests.has(key) || this.failed.has(key) || this.delegate.isFileCached(entry)) { continue }
        this.enqueue(entry)
      }
    }
    const current = this.requests.get(this.currentKey())
    if (current !== undefined && !current.running && this.activeCount < limit) { this.start(current) }
    if (!this.prefetchReady || !this.canPrefetch()) { return }
    for (const entry of this.targets()) {
      if (this.activeCount >= limit) { break }
      const request = this.requests.get(this.delegate.fileKey(entry))
      if (request !== undefined && !request.running && !request.cancellation.isCancelled()) { this.start(request) }
    }
  }
  private async start(request: ViewerFileRequest): Promise<void> {
    request.running = true
    this.activeCount++
    hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG,
      `[Coordinator] file-start name=${request.entry.name} active=${this.activeCount} current=${request.key === this.currentKey()}`)
    try {
      const onProgress = (progress: BinaryDownloadProgress): void => {
        if (request.session === this.session && request.key === this.currentKey()) { request.progress?.(progress) }
      }
      const path = await this.delegate.downloadOriginalFile(request.entry, onProgress,
        (): boolean => this.wanted(request), request.cancellation)
      if (!this.wanted(request)) { throw this.cancelled() }
      this.notifyReady(request, path)
      request.resolve(path)
      hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG, `[Coordinator] file-ready name=${request.entry.name}`)
    } catch (error) {
      // Do not loop-retry a failing neighbour. A new page or explicit current
      // request permits another attempt without an unbounded retry timer.
      if (request.session === this.session && !request.cancellation.isCancelled()) { this.failed.add(request.key) }
      request.reject(error as Object)
      hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG,
        `[Coordinator] file-ended name=${request.entry.name} cancelled=${request.cancellation.isCancelled()}`)
    } finally {
      this.activeCount = Math.max(0, this.activeCount - 1)
      if (this.requests.get(request.key) === request) { this.requests.delete(request.key) }
      this.pump()
    }
  }
}

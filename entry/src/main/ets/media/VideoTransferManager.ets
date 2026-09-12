import { DownloadDestination } from '../download/DownloadDestination'
import { StorageBudget } from '../download/StorageBudget'
import { DownloadTaskRecord } from '../model/FileEntry'
import { Context } from '@kit.AbilityKit'
import { fileIo } from '@kit.CoreFileKit'
import { media } from '@kit.MediaKit'
import { CacheManager } from '../download/CacheManager'
import { HttpTransport } from '../core/network/HttpTransport'
import { FileEntry, DownloadDescriptor } from '../model/FileEntry'
import { UgreenRemoteRepository } from '../repository/UgreenRemoteRepository'
import { ByteRangeStore } from './ByteRangeStore'
import {
  MediaLocalRecord,
  MediaLocalStore,
  RemoteFileSignature
} from './MediaLocalStore'

export type VideoTransferStatus = 'idle' | 'checking' | 'streaming' | 'queued' |
  'downloading' | 'partial' | 'completed' | 'failed'

export class VideoTransferState {
  sourceKey: string = ''
  status: VideoTransferStatus = 'idle'
  receivedBytes: number = 0
  totalBytes: number = 0
  localPath: string = ''
  durablePath: string = ''
  errorMessage: string = ''
  updatedAt: number = 0

  progress(): number {
    if (this.totalBytes <= 0) {
      return 0
    }
    return Math.min(100, Math.max(0, this.receivedBytes / this.totalBytes * 100))
  }
}

export class VideoSourceHandle {
  sourceKey: string = ''
  localPath: string = ''
  mediaSource: media.MediaSource | null = null
  totalBytes: number = 0
  streamType: string = 'file'
}

export type VideoTransferListener = (states: VideoTransferState[]) => void

class VideoTransferSession {
  entry: FileEntry = new FileEntry()
  signature: RemoteFileSignature = new RemoteFileSignature()
  descriptor: DownloadDescriptor = new DownloadDescriptor()
  sourceKey: string = ''
  streamTaskId: string = ''
  streamTaskClosed: boolean = false
  cachePath: string = ''
  partPath: string = ''
  totalBytes: number = 0
  ranges: ByteRangeStore = new ByteRangeStore()
  inFlight: Map<string, Promise<void>> = new Map<string, Promise<void>>()
  paused: boolean = false
  removed: boolean = false
  temporaryOnly: boolean = false
  closed: boolean = false
  downloadRequested: boolean = false
  downloadPromise: Promise<void> | null = null
  errorMessage: string = ''
  durablePath: string = ''
  destinationRoot: string = ''
  relativePath: string = ''
  lastPersistAt: number = 0
}

/**
 * Coordinates explicit durable downloads and the short-lived source selected
 * by AVPlayer. Playback itself is owned by AVPlayer's native HTTP/HLS buffer;
 * only an explicit Save/Download action writes resumable byte ranges to disk.
 */
export class VideoTransferManager {
  private static readonly CHUNK_BYTES: number = 512 * 1024
  private static readonly STAGING_DIRECTORY_NAME: string = 'ugreen-video-transfers'
  private context: Context | null = null
  private repository: UgreenRemoteRepository | null = null
  private cacheDirectory: string = ''
  private cacheLimitBytes: number = CacheManager.DEFAULT_LIMIT_BYTES
  private stagingDirectory: string = ''
  private initialized: boolean = false
  private initializedScopeKey: string = ''
  private store: MediaLocalStore = new MediaLocalStore()
  private transport: HttpTransport = new HttpTransport()
  private readerPaths: Map<string, string[]> = new Map<string, string[]>()
  private sessions: Map<string, VideoTransferSession> = new Map<string, VideoTransferSession>()
  private states: Record<string, VideoTransferState> = {}
  private listeners: VideoTransferListener[] = []

  async initialize(context: Context, repository: UgreenRemoteRepository,
    cacheDirectory: string, cacheLimitBytes: number): Promise<void> {
    this.context = context
    DownloadDestination.initialize(context)
    this.repository = repository
    this.cacheDirectory = cacheDirectory
    this.cacheLimitBytes = cacheLimitBytes > 0 ? cacheLimitBytes : CacheManager.DEFAULT_LIMIT_BYTES
    this.stagingDirectory = context.filesDir + '/' + VideoTransferManager.STAGING_DIRECTORY_NAME
    this.ensureDirectory(this.stagingDirectory)
    const scopeKey = repository.cacheScopeHash()
    if (this.initialized && this.initializedScopeKey === scopeKey) {
      return
    }
    if (this.initialized) {
      for (const session of this.sessions.values()) { session.paused = true; session.closed = true }
      for (const session of this.sessions.values()) {
        await this.closeStreamTask(session)
        if (session.downloadPromise !== null) { try { await session.downloadPromise } catch (_) {} }
      }
      await this.store.flush()
      this.sessions.clear()
      this.states = {}
    }
    this.store = new MediaLocalStore()
    await this.store.initialize(context, scopeKey)
    if (!this.initialized) {
      StorageBudget.onEvicted((path: string): void => {
        for (const record of this.store.snapshot()) {
          if (record.durablePath.length === 0 && (record.partPath === path || record.cachePath === path)) {
            record.partPath = ''
            record.cachePath = ''
            record.ranges = []
            record.receivedBytes = 0
            record.status = 'partial'
            this.store.put(record)
            this.sessions.delete(record.sourceKey)
            this.states[record.sourceKey] = new VideoTransferState()
          }
        }
        this.notify()
      })
    }
    this.initialized = true
    this.initializedScopeKey = scopeKey
    this.reconcileStoredRecords()
    this.archiveHistory()
    // Initialization can restore completed/partial records while the file
    // surface is already mounted.  Emit once so the right-side indicators do
    // not stay at "idle" until the next network event.
    this.notify()
  }

  onChange(listener: VideoTransferListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  stateFor(entry: FileEntry): VideoTransferState {
    const signature = this.signature(entry)
    const sourceKey = signature.key()
    const current = this.states[sourceKey]
    if (current !== undefined) {
      return this.copyState(current)
    }
    const stored = this.store.find(sourceKey)
    if (stored !== null) {
      const state = new VideoTransferState()
      state.sourceKey = sourceKey
      state.receivedBytes = stored.receivedBytes
      state.totalBytes = stored.totalBytes > 0 ? stored.totalBytes : entry.size
      const storedRanges = new ByteRangeStore()
      storedRanges.load(stored.ranges)
      const rangesComplete = state.totalBytes > 0 && storedRanges.complete(state.totalBytes)
      state.status = stored.status === 'downloaded' || stored.status === 'cached' || rangesComplete
        ? 'completed' : (stored.status === 'failed' ? 'failed' : 'partial')
      state.localPath = stored.durablePath.length > 0 ? stored.durablePath :
        (stored.cachePath.length > 0 ? stored.cachePath : stored.partPath)
      state.durablePath = stored.durablePath
      state.updatedAt = stored.updatedAt
      if (state.localPath.length > 0 && !CacheManager.exists(state.localPath)) {
        state.status = 'idle'
        state.localPath = ''
        state.durablePath = ''
      }
      return state
    }
    const state = new VideoTransferState()
    state.sourceKey = sourceKey
    return state
  }

  /**
   * Validate only durable video downloads represented by the directory the
   * user has just entered. This avoids a global Download scan and avoids a
   * filesystem stat for remote files that have never been downloaded.
   */
  async reconcileDirectoryDownloads(entries: FileEntry[]): Promise<void> {
    await this.requireInitialized()
    let changed = false
    for (const entry of entries) {
      if (entry.isDirectory) {
        continue
      }
      const signature = this.signature(entry)
      const sourceKey = signature.key()
      const record = this.store.find(sourceKey)
      if (record === null || record.durablePath.length === 0 ||
        this.validLocalPath(record.durablePath, signature)) {
        continue
      }

      const session = this.sessions.get(sourceKey)
      if (session !== undefined && session.downloadPromise !== null) {
        continue
      }
      if (session !== undefined) {
        session.closed = true
        await this.closeStreamTask(session)
        this.sessions.delete(sourceKey)
      }

      // Keep playback position and the remote signature, while removing the
      // stale user-file mapping and its completed byte ranges. A later play
      // can stream normally and a later download creates a fresh mapping.
      record.durablePath = ''
      record.userDownload = false
      record.cachePath = ''
      record.partPath = ''
      record.ranges = []
      record.receivedBytes = 0
      record.status = 'partial'
      this.store.put(record)

      const state = this.ensureState(sourceKey)
      state.status = 'idle'
      state.receivedBytes = 0
      state.totalBytes = 0
      state.localPath = ''
      state.durablePath = ''
      state.errorMessage = ''
      state.updatedAt = Date.now()
      changed = true
    }
    if (changed) {
      await this.store.flush()
      this.notify()
    }
  }

  async resolveLocal(entry: FileEntry): Promise<string> {
    await this.requireInitialized()
    const signature = this.signature(entry)
    const sourceKey = signature.key()
    const stored = this.store.find(sourceKey)
    if (stored !== null && stored.durablePath.length > 0 &&
      this.validLocalPath(stored.durablePath, signature)) {
      this.setCompletedState(sourceKey, stored.durablePath, stored.durablePath,
        stored.totalBytes > 0 ? stored.totalBytes : entry.size)
      return stored.durablePath
    }

    const cacheKey = this.cacheKey(sourceKey)
    const cachedPath = this.cacheDirectory.length > 0
      ? CacheManager.findExisting(this.cacheDirectory, entry.name, cacheKey) : ''
    if (cachedPath.length > 0 && this.validLocalPath(cachedPath, signature)) {
      const record = this.recordFromStored(stored, entry, signature)
      record.cachePath = cachedPath
      record.partPath = ''
      record.receivedBytes = signature.size > 0 ? signature.size : this.fileSize(cachedPath)
      record.totalBytes = signature.size > 0 ? signature.size : record.receivedBytes
      record.status = 'cached'
      this.store.put(record)
      this.setCompletedState(sourceKey, cachedPath, '', record.totalBytes)
      return cachedPath
    }

    // A source larger than the cache limit may have finished in the private
    // resumable staging area. It is a complete local source even though it is
    // intentionally not labelled as a cache file; use it directly and let a
    // later explicit Download promote it without another network request.
    if (stored !== null && stored.partPath.length > 0) {
      const totalBytes = stored.totalBytes > 0 ? stored.totalBytes : entry.size
      const storedRanges = new ByteRangeStore()
      storedRanges.load(stored.ranges)
      if (totalBytes > 0 && storedRanges.complete(totalBytes) &&
        this.validLocalPath(stored.partPath, signature)) {
        this.setCompletedState(sourceKey, stored.partPath, '', totalBytes)
        return stored.partPath
      }
    }

    if (stored !== null && stored.durablePath.length > 0) {
      // A user-owned file is never deleted just because its remote mapping is
      // stale. It is simply no longer eligible for this source version.
      this.store.remove(sourceKey)
    }
    return ''
  }

  async openSource(entry: FileEntry): Promise<VideoSourceHandle> {
    await this.requireInitialized()
    const localPath = await this.resolveLocal(entry)
    const handle = new VideoSourceHandle()
    const signature = this.signature(entry)
    handle.sourceKey = signature.key()
    if (localPath.length > 0) {
      StorageBudget.pin(localPath)
      const readerKey = this.signature(entry).key()
      const paths = this.readerPaths.get(readerKey) || []
      paths.push(localPath)
      this.readerPaths.set(readerKey, paths)
      handle.localPath = localPath
      handle.totalBytes = signature.size > 0 ? signature.size : this.fileSize(localPath)
      return handle
    }
    const session = await this.getSession(entry, signature)
    session.closed = false
    session.downloadRequested = false
    console.info('[UgreenVideo] source ready path=' + entry.path +
      ' entrySize=' + entry.size.toString() + ' total=' + session.totalBytes.toString() +
      ' local=' + (session.partPath.length > 0).toString())
    // Let AVPlayer own the network producer/consumer buffer.  The old path
    // attached a custom range-request delegate here and copied arbitrary byte
    // ranges into a sparse file.  That made the native demuxer race the
    // application's range writer (especially around moov/seek requests), so
    // a large file could stall or enter error before the first frame.  UGOS's
    // mediaPlayer URL already advertises byte ranges, and the web viewer uses
    // an HLS URL when its transcode service is available; both are supported
    // directly by the platform MediaSource implementation.
    const sourceHeaders: Record<string, string> = {}
    for (const key of Object.keys(session.descriptor.headers)) {
      sourceHeaders[key] = session.descriptor.headers[key]
    }
    const sourceContentType = this.responseContentType(entry)
    if (session.descriptor.streamType === 'hls') {
      sourceHeaders['Accept'] = 'application/vnd.apple.mpegurl, application/x-mpegURL, */*'
    } else if (sourceContentType.length > 0) {
      // Content-Type describes a response, not a GET request.  Supplying it
      // here can make relay gateways reject the request before AVPlayer sees
      // the actual response MIME; Accept is the appropriate hint.
      sourceHeaders['Accept'] = sourceContentType
    }
    const source = media.createMediaSourceWithUrl(session.descriptor.url, sourceHeaders)
    if (session.descriptor.streamType === 'hls') {
      try {
        source.setMimeType(media.AVMimeTypes.APPLICATION_M3U8)
      } catch (error) {
        console.warn('[UgreenVideo] set HLS mime type failed: ' + JSON.stringify(error))
      }
    }
    try {
      // The app owns persistence and routing. The system offline cache is
      // opaque and would make cache accounting and promotion impossible.
      source.enableOfflineCache(false)
    } catch (_) {
      // API 23+ exposes this method; leaving the default disabled is safe on
      // older runtime implementations.
    }
    const state = this.ensureState(session.sourceKey)
    state.status = 'streaming'
    state.totalBytes = session.totalBytes
    state.receivedBytes = session.ranges.coveredBytes()
    state.localPath = session.partPath
    state.errorMessage = ''
    this.notify()
    handle.mediaSource = source
    handle.totalBytes = session.totalBytes
    handle.streamType = session.descriptor.streamType
    return handle
  }

  /**
   * Return a fresh URL that a remote Cast+ / DLNA sink can open directly.
   * The AVPlayer MediaSource is local to this UIAbility and cannot be handed
   * to a remote sink. The download endpoint returns a signed URL, so the
   * remote device does not need the app's authentication headers.
   */
  async castDescriptor(entry: FileEntry): Promise<DownloadDescriptor> {
    await this.requireInitialized()
    if (this.repository === null) {
      throw new Error('远端服务尚未初始化')
    }
    const descriptor = await this.repository.downloadDescriptor(entry.path)
    if (descriptor.size <= 0 && entry.size > 0) {
      descriptor.size = entry.size
    }
    return descriptor
  }

  async requestDownload(entry: FileEntry, destinationRoot: string = '',
    relativePath: string = ''): Promise<void> {
    await this.requireInitialized()
    const signature = this.signature(entry)
    const sourceKey = signature.key()
    const existing = await this.resolveLocal(entry)
    if (existing.length > 0 && this.isDurablePath(existing, signature)) {
      return
    }
    if (existing.length > 0) {
      // A complete cache hit can be promoted without requesting a new token.
      // This keeps an offline Save/Download action from re-downloading bytes
      // that are already present and makes the cache-to-Download hand-off
      // atomic from the user's point of view.
      const activeSession = this.sessions.get(sourceKey)
      if (activeSession !== undefined && activeSession.durablePath.length === 0) {
        // Reuse the session that the player is already reading. Creating a
        // second session here would remove its cache path underneath AVPlayer
        // and reintroduce a blank frame while the download is promoted.
        activeSession.cachePath = existing
        activeSession.partPath = existing
        activeSession.destinationRoot = destinationRoot
        activeSession.relativePath = relativePath
        activeSession.totalBytes = signature.size > 0 ? signature.size : this.fileSize(existing)
        activeSession.ranges.clear()
        activeSession.ranges.add(0, activeSession.totalBytes)
        await this.startDownload(activeSession)
        return
      }
      await this.promoteCachedFile(entry, signature, existing, destinationRoot, relativePath)
      return
    }
    const session = await this.getSession(entry, signature)
    session.destinationRoot = destinationRoot
    session.relativePath = relativePath
    session.paused = false
    session.temporaryOnly = false
    await this.startDownload(session)
  }

  snapshotTasks(): DownloadTaskRecord[] {
    const tasks: DownloadTaskRecord[] = []
    for (const record of this.store.snapshot()) {
      if (!record.userDownload) { continue }
      const task = new DownloadTaskRecord()
      task.id = 'video:' + record.sourceKey
      task.sourceKey = record.sourceKey
      task.remotePath = record.remotePath
      task.name = record.name
      task.mimeType = 'video/*'
      task.size = record.totalBytes || record.size
      task.createdAt = record.updatedAt
      task.updatedAt = record.updatedAt
      task.finalPath = record.durablePath
      task.stagingPath = record.partPath
      task.receivedBytes = record.receivedBytes
      const state = this.states[record.sourceKey]
      const session = this.sessions.get(record.sourceKey)
      task.status = record.durablePath.length > 0 ? 'completed' :
        (state !== undefined && state.status === 'failed' ? 'failed' :
          (session !== undefined && session.downloadPromise !== null && !session.paused ? 'downloading' : 'paused'))
      task.errorMessage = state === undefined ? '' : state.errorMessage
      tasks.push(task)
    }
    const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000
    let completed = 0
    return tasks.sort((a: DownloadTaskRecord, b: DownloadTaskRecord): number => b.updatedAt - a.updatedAt)
      .filter((task: DownloadTaskRecord): boolean => {
        if (task.status !== 'completed') { return true }
        completed += 1
        return completed <= 200 && task.updatedAt >= cutoff
      })
  }

  async toggleTask(id: string): Promise<void> {
    const key = id.substring('video:'.length)
    const session = this.sessions.get(key)
    if (session !== undefined && session.downloadPromise !== null) { session.paused = true; this.notify(); return }
    const record = this.store.find(key)
    if (record === null || record.durablePath.length > 0) { return }
    const entry = new FileEntry()
    entry.name = record.name
    entry.path = record.remotePath
    entry.size = record.size
    entry.modifiedTime = record.modifiedTime
    entry.etag = record.etag
    entry.checksum = record.checksum
    this.requestDownload(entry, '', record.relativePath).catch((): void => {})
  }

  async removeTask(id: string): Promise<void> {
    const key = id.substring('video:'.length)
    const session = this.sessions.get(key)
    if (session !== undefined && session.downloadPromise !== null) {
      session.removed = true
      session.paused = true
      await session.downloadPromise.catch((): void => {})
    }
    const record = this.store.find(key)
    if (record !== null) {
      if (record.durablePath.length === 0) {
        this.removeFile(record.partPath)
        this.store.remove(key)
      } else {
        record.userDownload = false
        this.store.put(record)
      }
    }
    this.notify()
  }

  async requestCachedFile(entry: FileEntry): Promise<string> {
    const existing = await this.resolveLocal(entry)
    if (existing.length > 0) { return existing }
    const session = await this.getSession(entry, this.signature(entry))
    if (session.downloadPromise === null) { session.temporaryOnly = true }
    await this.startDownload(session)
    return session.partPath
  }

  async savePlaybackPosition(entry: FileEntry, positionMs: number): Promise<void> {
    await this.requireInitialized()
    const signature = this.signature(entry)
    const record = this.recordFromStored(this.store.find(signature.key()), entry, signature)
    record.playbackPositionMs = Math.max(0, Math.floor(positionMs))
    this.store.put(record)
  }

  async playbackPosition(entry: FileEntry): Promise<number> {
    await this.requireInitialized()
    const record = this.store.find(this.signature(entry).key())
    return record === null ? 0 : Math.max(0, record.playbackPositionMs)
  }

  async releaseSource(entry: FileEntry): Promise<void> {
    const sourceKey = this.signature(entry).key()
    const paths = this.readerPaths.get(sourceKey) || []
    const local = paths.shift()
    if (local !== undefined) { StorageBudget.unpin(local) }
    if (paths.length === 0) { this.readerPaths.delete(sourceKey) }
    const session = this.sessions.get(sourceKey)
    if (session === undefined) {
      return
    }
    session.closed = true
    await this.closeStreamTask(session)
    // Keep the partial file and metadata for the next open. A download in
    // progress intentionally continues after the player has been closed.
    if (session.downloadPromise === null && !session.downloadRequested &&
      session.partPath === session.cachePath + '.part' &&
      session.ranges.complete(session.totalBytes)) {
      await this.finalizeCache(session)
    }
    // Native network playback does not write through the old custom loader.
    // Discard that short-lived session when it has no resumable bytes so the
    // next open mints a fresh HLS/mediaPlayer URL instead of reusing an expired
    // transcode task.  Keep genuine partial download records intact.
    if (session.downloadPromise === null && !session.downloadRequested &&
      session.ranges.coveredBytes() <= 0 && session.durablePath.length === 0) {
      this.sessions.delete(sourceKey)
      const state = this.ensureState(sourceKey)
      state.status = 'idle'
      state.receivedBytes = 0
      state.totalBytes = 0
      state.localPath = ''
      state.errorMessage = ''
      state.updatedAt = Date.now()
      this.notify()
    }
  }

  async clearCache(entry: FileEntry): Promise<void> {
    await this.requireInitialized()
    const signature = this.signature(entry)
    const session = this.sessions.get(signature.key())
    if (session !== undefined && session.downloadPromise !== null) {
      throw new Error('视频正在下载，暂不能清理')
    }
    const record = this.store.find(signature.key())
    if (record !== null && record.durablePath.length > 0) {
      return
    }
    if (record !== null) {
      this.removeFile(record.cachePath)
      this.removeFile(record.partPath)
      this.store.remove(signature.key())
    }
    if (session !== undefined) {
      await this.closeStreamTask(session)
      this.removeFile(session.cachePath)
      if (session.partPath !== session.cachePath) {
        this.removeFile(session.partPath)
      }
      this.sessions.delete(signature.key())
    }
    const clearedState = new VideoTransferState()
    clearedState.sourceKey = signature.key()
    this.states[signature.key()] = clearedState
    this.notify()
  }

  async flush(): Promise<void> {
    await this.store.flush()
  }

  private async getSession(entry: FileEntry, signature: RemoteFileSignature): Promise<VideoTransferSession> {
    const existing = this.sessions.get(signature.key())
    if (existing !== undefined) {
      return existing
    }
    if (this.repository === null) {
      throw new Error('远端服务尚未初始化')
    }
    // Match the official UGOS web viewer first: it prepares a short-lived HLS
    // playlist and lets the media engine fetch segments as they become ready.
    // Some NAS versions ship without a transcode worker (9404); in that case
    // the authenticated Range-capable mediaPlayer URL still gives AVPlayer a
    // native progressive HTTP source, so degrade without surfacing an error.
    let descriptor: DownloadDescriptor
    try {
      descriptor = await this.repository.streamDescriptor(entry)
    } catch (error) {
      console.warn('[UgreenVideo] HLS preparation unavailable, fallback to mediaPlayer: ' +
        String(error))
      descriptor = await this.repository.mediaPlayerDescriptor(entry)
    }
    if (descriptor.size <= 0 && entry.size > 0) {
      descriptor.size = entry.size
    }
    if (descriptor.etag.length === 0) {
      descriptor.etag = entry.etag
    }
    if (descriptor.checksum.length === 0) {
      descriptor.checksum = entry.checksum
    }
    const session = new VideoTransferSession()
    session.entry = this.copyEntry(entry)
    session.signature = signature
    session.descriptor = descriptor
    session.sourceKey = signature.key()
    session.streamTaskId = descriptor.streamTaskId
    session.streamTaskClosed = false
    session.totalBytes = descriptor.size > 0 ? descriptor.size : signature.size
    session.cachePath = CacheManager.cachePath(this.cacheDirectory, entry.name,
      this.cacheKey(session.sourceKey))
    // A known movie larger than the disposable cache limit streams into the
    // private resumable staging area from the start. Playback must not fail
    // halfway through simply because the cache policy is smaller than the
    // source; an explicit Download can still promote this same file later.
    session.partPath = session.totalBytes > this.cacheLimitBytes
      ? this.stagingPath(session.sourceKey) : session.cachePath + '.part'
    const stored = this.store.find(session.sourceKey)
    if (stored !== null) {
      session.ranges.load(stored.ranges)
      session.totalBytes = Math.max(session.totalBytes, stored.totalBytes)
      session.durablePath = stored.durablePath
      if (stored.cachePath.length > 0) {
        const storedCacheSize = this.fileSize(stored.cachePath)
        const cacheMatchesSize = storedCacheSize > 0 &&
          (session.totalBytes <= 0 || storedCacheSize === session.totalBytes)
        if (cacheMatchesSize) {
          session.partPath = stored.cachePath
          if (session.totalBytes > 0 && session.ranges.coveredBytes() <= 0) {
            session.ranges.add(0, session.totalBytes)
          }
        } else {
          // A truncated cache must never be treated as a complete range just
          // because its old metadata said "cached". It will be refetched into
          // the normal keyed .part path below.
          this.removeFile(stored.cachePath)
          session.ranges.clear()
        }
      }
      if (stored.partPath.length > 0 && this.fileSize(stored.partPath) > 0) {
        session.partPath = stored.partPath
      }
    }
    this.sessions.set(session.sourceKey, session)
    const state = this.ensureState(session.sourceKey)
    state.status = 'checking'
    state.totalBytes = session.totalBytes
    state.receivedBytes = session.ranges.coveredBytes()
    state.localPath = session.partPath
    this.notify()
    return session
  }

  /**
   * The web viewer sends a close beacon for every HLS task.  Keep the same
   * lifecycle here, but never make leaving the viewer fail when a relay is
   * already offline or has expired the short-lived task.
   */
  private async closeStreamTask(session: VideoTransferSession): Promise<void> {
    if (session.streamTaskClosed || session.streamTaskId.length === 0 || this.repository === null) {
      return
    }
    session.streamTaskClosed = true
    try {
      await this.repository.closeStreamTask(session.streamTaskId, 1)
    } catch (error) {
      console.warn('[UgreenVideo] close HLS task failed: ' + String(error))
    }
  }

  private async promoteCachedFile(entry: FileEntry, signature: RemoteFileSignature,
    cachedPath: string, destinationRoot: string = '', relativePath: string = ''): Promise<void> {
    const totalBytes = signature.size > 0 ? signature.size : this.fileSize(cachedPath)
    if (totalBytes <= 0 || this.fileSize(cachedPath) !== totalBytes) {
      throw new Error('视频缓存文件不完整')
    }
    const session = new VideoTransferSession()
    session.entry = this.copyEntry(entry)
    session.signature = signature
    session.sourceKey = signature.key()
    session.cachePath = cachedPath
    session.partPath = cachedPath
    session.totalBytes = totalBytes
    session.ranges.add(0, totalBytes)
    session.downloadRequested = true
    session.closed = false
    session.destinationRoot = destinationRoot
    session.relativePath = relativePath
    this.sessions.set(session.sourceKey, session)
    const state = this.ensureState(session.sourceKey)
    state.status = 'queued'
    state.receivedBytes = totalBytes
    state.totalBytes = totalBytes
    state.localPath = cachedPath
    state.errorMessage = ''
    this.notify()
    await this.promoteToDownload(session)
    state.status = 'completed'
    state.receivedBytes = totalBytes
    state.totalBytes = totalBytes
    state.localPath = session.durablePath
    state.durablePath = session.durablePath
    state.updatedAt = Date.now()
    this.notify()
  }

  private async startDownload(session: VideoTransferSession): Promise<void> {
    if (session.downloadPromise !== null) {
      await session.downloadPromise
      return
    }
    session.closed = false
    session.paused = false
    session.downloadRequested = true
    this.persistSession(session)
    StorageBudget.pin(session.partPath)
    const pinnedPath = session.partPath
    session.downloadPromise = (async (): Promise<void> => {
      await this.store.flush()
      await this.useDownloadDescriptor(session)
      const state = this.ensureState(session.sourceKey)
      state.status = 'queued'
      state.totalBytes = session.totalBytes
      state.receivedBytes = session.ranges.coveredBytes()
      state.localPath = session.partPath
      state.errorMessage = ''
      this.notify()
      await this.downloadWhole(session)
    })()
    try {
      await session.downloadPromise
    } catch (error) {
      session.errorMessage = this.errorMessage(error)
      const state = this.ensureState(session.sourceKey)
      state.status = session.paused ? 'partial' : 'failed'
      state.errorMessage = session.paused ? '' : session.errorMessage
      this.persistSession(session)
      this.notify()
      throw error as Error
    } finally {
      session.downloadPromise = null
      StorageBudget.unpin(pinnedPath)
      if (session.removed) {
        this.removeFile(pinnedPath)
        this.store.remove(session.sourceKey)
        this.sessions.delete(session.sourceKey)
        this.states[session.sourceKey] = new VideoTransferState()
      }
      this.notify()
    }
  }

  private async useDownloadDescriptor(session: VideoTransferSession): Promise<void> {
    if (this.repository === null) {
      throw new Error('远端服务尚未初始化')
    }
    const descriptor = await this.repository.downloadDescriptor(session.entry.path)
    if (descriptor.url.length === 0) {
      throw new Error('下载接口没有返回有效地址')
    }
    session.descriptor = descriptor
    if (descriptor.size > 0) {
      session.totalBytes = Math.max(session.totalBytes, descriptor.size)
    }
  }

  private async fetchChunk(session: VideoTransferSession, start: number, length: number): Promise<void> {
    const key = start.toString() + ':' + length.toString()
    const active = session.inFlight.get(key)
    if (active !== undefined) {
      await active
      return
    }
    const request = this.fetchChunkInternal(session, start, length)
    session.inFlight.set(key, request)
    try {
      await request
    } finally {
      if (session.inFlight.get(key) === request) {
        session.inFlight.delete(key)
      }
    }
  }

  private async fetchChunkInternal(session: VideoTransferSession, start: number,
    length: number): Promise<void> {
    const result = await this.transport.requestBinaryRange(session.descriptor.url, start, length,
      session.descriptor.headers)
    console.info('[UgreenVideo] range path=' + session.entry.path +
      ' start=' + start.toString() + ' length=' + length.toString() +
      ' status=' + result.responseCode.toString() + ' bytes=' + result.bytes.byteLength.toString() +
      ' total=' + result.totalSize.toString())
    if (result.totalSize > 0) {
      session.totalBytes = Math.max(session.totalBytes, result.totalSize)
    }
    const actualStart = result.start
    const actualEnd = actualStart + result.bytes.byteLength
    if (actualStart !== start) {
      throw new Error('视频分段位置不一致')
    }
    const expectedEnd = session.totalBytes > 0
      ? Math.min(session.totalBytes, start + length) : start + length
    if (actualEnd < expectedEnd) {
      throw new Error('视频分段响应不完整')
    }
    if (actualEnd > start + length) {
      throw new Error('视频分段响应超出请求范围')
    }
    if (!session.downloadRequested && this.cacheDirectory.length > 0 &&
      session.partPath.startsWith(this.cacheDirectory + '/')) {
      // Count the existing sparse .part file toward the cache limit while
      // protecting it from eviction. Passing it as targetPath would exclude
      // the file from the projected total on every chunk and let a streamed
      // movie grow without bound.
      await CacheManager.prepareForIncoming(this.cacheDirectory, this.cacheLimitBytes,
        result.bytes.byteLength, '', [session.partPath, session.cachePath])
    }
    if (session.paused || session.removed) { throw new Error('下载已暂停') }
    this.writeAt(session.partPath, actualStart, result.bytes)
    session.ranges.add(actualStart, actualEnd)
    if (session.totalBytes > 0 && session.ranges.complete(session.totalBytes)) {
      await this.finalizeCacheIfStreaming(session)
    }
    this.persistSession(session)
    const complete = session.totalBytes > 0 && session.ranges.complete(session.totalBytes)
    const state = this.ensureState(session.sourceKey)
    state.status = complete && !session.downloadRequested ? 'completed' :
      (session.downloadRequested ? 'downloading' : 'streaming')
    state.totalBytes = session.totalBytes
    state.receivedBytes = session.ranges.coveredBytes()
    state.localPath = session.partPath
    state.updatedAt = Date.now()
    this.notify()
  }

  private async downloadWhole(session: VideoTransferSession): Promise<void> {
    try {
      const state = this.ensureState(session.sourceKey)
      state.status = 'downloading'
      this.notify()
      let cursor = 0
      let safety = 0
      while (true) {
        if (session.paused || session.removed) { throw new Error('下载已暂停') }
        safety += 1
        if (safety > 100000) {
          throw new Error('视频下载区间异常')
        }
        if (session.totalBytes > 0 && session.ranges.complete(session.totalBytes)) {
          break
        }
        const targetEnd = session.totalBytes > 0
          ? session.totalBytes : cursor + VideoTransferManager.CHUNK_BYTES
        const missing = session.ranges.nextMissing(cursor, targetEnd)
        if (missing === null) {
          cursor = targetEnd
          if (session.totalBytes <= 0) {
            // A response without a total size cannot be promoted safely.
            break
          }
          continue
        }
        const length = Math.min(VideoTransferManager.CHUNK_BYTES, missing.end - missing.start)
        await this.fetchChunk(session, missing.start, length)
        cursor = missing.start + length
        if (session.totalBytes <= 0 && cursor >= VideoTransferManager.CHUNK_BYTES) {
          // The first ranged response normally gives Content-Range. If it
          // does not, stop instead of claiming a complete durable file.
          throw new Error('视频大小未知，无法完成下载')
        }
      }
      if (session.totalBytes <= 0 || !session.ranges.complete(session.totalBytes)) {
        throw new Error('视频下载不完整')
      }
      await this.promoteToDownload(session)
      const finalState = this.ensureState(session.sourceKey)
      finalState.status = 'completed'
      finalState.receivedBytes = session.totalBytes
      finalState.totalBytes = session.totalBytes
      finalState.localPath = session.durablePath.length > 0 ? session.durablePath : session.partPath
      finalState.durablePath = session.durablePath
      finalState.errorMessage = ''
      finalState.updatedAt = Date.now()
      this.notify()
    } catch (error) {
      session.errorMessage = this.errorMessage(error)
      const state = this.ensureState(session.sourceKey)
      state.status = 'failed'
      state.errorMessage = session.errorMessage
      state.receivedBytes = session.ranges.coveredBytes()
      state.totalBytes = session.totalBytes
      state.localPath = session.partPath
      state.updatedAt = Date.now()
      this.persistSession(session)
      this.notify()
      throw error as Error
    }
  }

  private async waitForInflight(session: VideoTransferSession): Promise<void> {
    while (session.inFlight.size > 0) {
      const pending: Promise<void>[] = []
      session.inFlight.forEach((request: Promise<void>): void => {
        pending.push(request)
      })
      if (pending.length === 0) {
        return
      }
      await Promise.all(pending)
    }
  }

  private async promoteToDownload(session: VideoTransferSession): Promise<void> {
    if (session.paused || session.removed) { throw new Error('下载已暂停') }
    if (session.temporaryOnly) {
      session.downloadRequested = false
      await this.finalizeCache(session)
      return
    }
    const source = session.partPath
    const finalPath = await DownloadDestination.save(source,
      session.relativePath.length > 0 ? session.relativePath : session.entry.name)
    session.durablePath = finalPath
    session.partPath = finalPath
    const record = this.recordFromStored(this.store.find(session.sourceKey), session.entry,
      session.signature)
    record.durablePath = finalPath
    record.cachePath = ''
    record.partPath = ''
    record.ranges = session.ranges.serialize()
    record.receivedBytes = session.totalBytes
    record.totalBytes = session.totalBytes
    record.status = 'downloaded'
    record.userDownload = true
    this.store.put(record)
    await this.store.flush()
    await DownloadDestination.acknowledge(source)
    this.archiveHistory()
  }

  private async finalizeCacheIfStreaming(session: VideoTransferSession): Promise<void> {
    if (session.downloadRequested || session.durablePath.length > 0 ||
      session.partPath !== session.cachePath + '.part') {
      return
    }
    await this.finalizeCache(session)
  }

  private async finalizeCache(session: VideoTransferSession): Promise<void> {
    if (session.totalBytes <= 0 || !session.ranges.complete(session.totalBytes)) {
      return
    }
    if (session.partPath.endsWith('.part') && this.fileSize(session.partPath) > 0) {
      this.removeFile(session.cachePath)
      fileIo.renameSync(session.partPath, session.cachePath)
      session.partPath = session.cachePath
      const record = this.recordFromStored(this.store.find(session.sourceKey), session.entry,
        session.signature)
      record.cachePath = session.cachePath
      record.partPath = ''
      record.ranges = session.ranges.serialize()
      record.receivedBytes = session.totalBytes
      record.totalBytes = session.totalBytes
      record.status = 'cached'
      this.store.put(record)
    }
  }

  private persistSession(session: VideoTransferSession): void {
    const now = Date.now()
    if (now - session.lastPersistAt < 250 &&
      session.ranges.coveredBytes() < session.totalBytes) {
      return
    }
    session.lastPersistAt = now
    const record = this.recordFromStored(this.store.find(session.sourceKey), session.entry,
      session.signature)
    const cacheComplete = !session.downloadRequested && session.durablePath.length === 0 &&
      session.partPath === session.cachePath && session.totalBytes > 0 &&
      session.ranges.complete(session.totalBytes)
    record.cachePath = cacheComplete ? session.cachePath :
      (session.partPath.startsWith(this.stagingDirectory + '/') ? '' : session.cachePath)
    record.partPath = cacheComplete ? '' : session.partPath
    record.userDownload = record.userDownload || (session.downloadRequested && !session.temporaryOnly)
    record.relativePath = session.relativePath
    record.ranges = session.ranges.serialize()
    record.receivedBytes = session.ranges.coveredBytes()
    record.totalBytes = session.totalBytes
    record.status = cacheComplete ? 'cached' : 'partial'
    this.store.put(record)
  }

  private recordFromStored(stored: MediaLocalRecord | null, entry: FileEntry,
    signature: RemoteFileSignature): MediaLocalRecord {
    const record = stored === null ? new MediaLocalRecord() : stored
    record.sourceKey = signature.key()
    record.scopeKey = signature.scopeKey
    record.remotePath = entry.path
    record.name = entry.name
    record.size = signature.size
    record.modifiedTime = signature.modifiedTime
    record.etag = signature.etag
    record.checksum = signature.checksum
    return record
  }

  private signature(entry: FileEntry): RemoteFileSignature {
    if (this.repository !== null) {
      return this.repository.signatureForFile(entry)
    }
    return new RemoteFileSignature('', entry.path, entry.size, entry.modifiedTime,
      entry.etag, entry.checksum)
  }

  private cacheKey(sourceKey: string): string {
    return 'video-original-v1:' + sourceKey
  }

  private stagingPath(sourceKey: string): string {
    return this.stagingDirectory + '/' + CacheManager.hash(sourceKey) + '.part'
  }

  private ensureState(sourceKey: string): VideoTransferState {
    const current = this.states[sourceKey]
    if (current !== undefined) {
      return current
    }
    const created = new VideoTransferState()
    created.sourceKey = sourceKey
    this.states[sourceKey] = created
    return created
  }

  private setCompletedState(sourceKey: string, localPath: string, durablePath: string,
    totalBytes: number): void {
    const state = this.ensureState(sourceKey)
    state.status = 'completed'
    state.receivedBytes = totalBytes
    state.totalBytes = totalBytes
    state.localPath = localPath
    state.durablePath = durablePath
    state.errorMessage = ''
    state.updatedAt = Date.now()
    this.notify()
  }

  private notify(): void {
    const result: VideoTransferState[] = []
    for (const key of Object.keys(this.states)) {
      result.push(this.copyState(this.states[key]))
    }
    for (const listener of this.listeners.slice()) {
      try {
        listener(result)
      } catch (error) {
        console.warn('[UgreenMedia] transfer listener failed: ' + JSON.stringify(error))
      }
    }
  }

  private copyState(source: VideoTransferState): VideoTransferState {
    const result = new VideoTransferState()
    result.sourceKey = source.sourceKey
    result.status = source.status
    result.receivedBytes = source.receivedBytes
    result.totalBytes = source.totalBytes
    result.localPath = source.localPath
    result.durablePath = source.durablePath
    result.errorMessage = source.errorMessage
    result.updatedAt = source.updatedAt
    return result
  }

  private validLocalPath(path: string, signature: RemoteFileSignature): boolean {
    if (!CacheManager.exists(path)) {
      return false
    }
    const size = this.fileSize(path)
    return signature.size <= 0 || size === signature.size
  }

  private isDurablePath(path: string, signature: RemoteFileSignature): boolean {
    const stored = this.store.find(signature.key())
    return stored !== null && stored.durablePath === path && this.validLocalPath(path, signature)
  }

  private archiveHistory(): void {
    const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000
    const completed = this.store.snapshot().filter((record: MediaLocalRecord): boolean =>
      record.userDownload && record.durablePath.length > 0).sort(
      (a: MediaLocalRecord, b: MediaLocalRecord): number => b.updatedAt - a.updatedAt)
    for (let index = 0; index < completed.length; index += 1) {
      const record = completed[index]
      if (index >= 200 || record.updatedAt < cutoff) {
        // Keep the durable mapping and playback position; archive only list history.
        record.userDownload = false
        this.store.put(record)
      }
    }
  }

  private reconcileStoredRecords(): void {
    for (const record of this.store.snapshot()) {
      if (record.durablePath.length > 0 && !CacheManager.exists(record.durablePath)) {
        this.store.remove(record.sourceKey)
      } else if (record.partPath.length > 0 && !CacheManager.exists(record.partPath)) {
        record.partPath = ''
        record.ranges = []
        record.receivedBytes = 0
        record.status = 'partial'
        this.store.put(record)
      }
    }
  }

  private async requireInitialized(): Promise<void> {
    if (!this.initialized || this.context === null || this.repository === null) {
      throw new Error('视频服务尚未初始化')
    }
  }

  private copyEntry(source: FileEntry): FileEntry {
    const result = new FileEntry()
    result.name = source.name
    result.path = source.path
    result.isDirectory = source.isDirectory
    result.size = source.size
    result.modifiedTime = source.modifiedTime
    result.createdTime = source.createdTime
    result.childCount = source.childCount
    result.rootType = source.rootType
    result.intranetShareId = source.intranetShareId
    result.thumbnailUrl = source.thumbnailUrl
    result.coverUrl = source.coverUrl
    result.mimeType = source.mimeType
    result.etag = source.etag
    result.checksum = source.checksum
    return result
  }

  private responseContentType(entry: FileEntry): string {
    const declared = entry.mimeType.trim().toLowerCase()
    // Some list APIs put a human label such as "video" in type_name.  Passing
    // that label as Content-Type makes AVPlayer reject an otherwise valid MP4.
    if (declared.indexOf('/') > 0 && declared.indexOf(' ') < 0) {
      return declared
    }
    const dot = entry.name.lastIndexOf('.')
    const extension = dot >= 0 ? entry.name.substring(dot + 1).toLowerCase() : ''
    switch (extension) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4'
      case 'mov':
        return 'video/quicktime'
      case 'webm':
        return 'video/webm'
      case 'mkv':
        return 'video/x-matroska'
      case 'avi':
        return 'video/x-msvideo'
      case 'ts':
        return 'video/mp2t'
      case 'm3u8':
        return 'application/vnd.apple.mpegurl'
      default:
        return ''
    }
  }

  private writeAt(path: string, offset: number, bytes: Uint8Array): void {
    this.ensureParentDirectory(path)
    StorageBudget.admit(path, Math.max(this.fileSize(path), offset + bytes.byteLength))
    const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE)
    try {
      let written = 0
      while (written < bytes.byteLength) {
        const chunk = bytes.slice(written)
        const count = fileIo.writeSync(file.fd, chunk.buffer as ArrayBuffer, { offset: offset + written })
        if (count <= 0) { throw new Error('写入视频文件失败') }
        written += count
      }
      StorageBudget.sync(path)
    } finally {
      fileIo.closeSync(file.fd)
    }
  }

  private readAt(path: string, offset: number, length: number): ArrayBuffer {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY)
    const buffer = new ArrayBuffer(length)
    try {
      const read = fileIo.readSync(file.fd, buffer, { offset: offset, length: length })
      if (read !== length) {
        throw new Error('视频缓存区间尚未完整写入')
      }
      return buffer
    } finally {
      fileIo.closeSync(file.fd)
    }
  }

  private fileSize(path: string): number {
    if (path.length === 0) {
      return 0
    }
    try {
      return fileIo.statSync(path).size
    } catch (_) {
      return 0
    }
  }

  private ensureDirectory(path: string): void {
    try {
      fileIo.mkdirSync(path, true)
    } catch (_) {
      // The directory may already exist.
    }
  }

  private ensureParentDirectory(path: string): void {
    const slash = path.lastIndexOf('/')
    if (slash > 0) {
      this.ensureDirectory(path.substring(0, slash))
    }
  }

  private removeFile(path: string): void {
    if (path.length === 0) {
      return
    }
    try {
      fileIo.unlinkSync(path)
      StorageBudget.sync(path)
    } catch (_) {
      // Cache eviction or a previous cleanup may have removed it already.
    }
  }

  private uniqueFinalPath(directory: string, name: string): string {
    const safeName = this.safeFileName(name)
    let candidate = directory.replace(/[\\/]$/, '') + '/' + safeName
    let index = 1
    while (CacheManager.exists(candidate)) {
      const dot = safeName.lastIndexOf('.')
      const stem = dot > 0 ? safeName.substring(0, dot) : safeName
      const extension = dot > 0 ? safeName.substring(dot) : ''
      candidate = directory.replace(/[\\/]$/, '') + '/' + stem + ' (' + index.toString() + ')' + extension
      index += 1
    }
    return candidate
  }

  private safeRelativePath(path: string): string {
    const parts = path.split(/[\\/]+/)
    const safe: string[] = []
    for (const part of parts) {
      const value = part.trim()
      if (value.length === 0 || value === '.' || value === '..') {
        continue
      }
      safe.push(this.safeFileName(value))
    }
    return safe.join('/')
  }

  private safeFileName(name: string): string {
    const trimmed = name.trim()
    if (trimmed.length === 0) {
      return 'ugreen-video-' + Date.now().toString()
    }
    return trimmed.replace(/[\\/:*?"<>|]/g, '_')
  }

  private errorMessage(error: Object): string {
    if (error instanceof Error && error.message.length > 0) {
      return error.message
    }
    return '视频传输失败，请重试'
  }
}

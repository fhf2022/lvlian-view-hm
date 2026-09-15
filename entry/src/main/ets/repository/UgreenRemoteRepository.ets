import { Context } from '@kit.AbilityKit'
import { DownloadManager } from '../download/DownloadManager'
import { CacheManager } from '../download/CacheManager'
import { BinaryProgressListener, HttpTransport } from '../core/network/HttpTransport'
import { UgreenDirectoryPage, UgreenRemoteClient } from '../ugreen/UgreenRemoteClient'
import { DownloadDescriptor, FileEntry, RootDirectory, LoginResult } from '../model/FileEntry'
import { RemoteFileSignature } from '../media/MediaLocalStore'
import { ThumbnailNormalizer } from '../media/ThumbnailNormalizer'
import { ThumbnailProfile } from '../media/ThumbnailPolicy'
import { ThumbnailCacheStore } from '../media/ThumbnailCacheStore'
import { DirectoryMetadataPage, DirectoryMetadataSnapshot, DirectoryMetadataStore } from './DirectoryMetadataStore'
import { NetworkPolicy } from '../core/network/NetworkPolicy'
import {
  DirectoryIndexedSnapshot,
  DirectoryQuery,
  DirectoryTimeline,
  DirectoryTimelineLocation,
  DirectoryTimelinePolicy
} from '../model/DirectoryTimeline'

interface DirectoryCacheItem {
  entries: FileEntry[]
  expiresAt: number
  lastAccessAt: number
  contentSignature: string
}

export type RemoteSearchScope = 'current' | 'descendants'
export type RemoteSearchListener = (entries: FileEntry[]) => void

interface SearchDirectory {
  path: string
  rootType: number
}

export class UgreenRemoteRepository {
  private static readonly DIRECTORY_CACHE_TTL_MS: number = 30 * 1000
  private static readonly DIRECTORY_CACHE_MAX_ENTRIES: number = 16
  // The recycle repository lives below a first-level folder, so listing it is
  // always an ordinary path traversal. Concrete paths must use root_type 3;
  // with 4 the server ignores the path and re-returns the root collection.
  private static readonly RECYCLE_ROOT_TYPE: number = 3
  private transport: HttpTransport = new HttpTransport()
  private client: UgreenRemoteClient = new UgreenRemoteClient(this.transport)
  private downloadManager: DownloadManager = new DownloadManager(this.transport)
  private directoryMetadataStore: DirectoryMetadataStore = new DirectoryMetadataStore()
  private metadataInitPromise: Promise<void> | null = null
  private metadataScope: string = ''
  private directoryCache: Map<string, DirectoryCacheItem> = new Map<string, DirectoryCacheItem>()
  private directoryPageCache: Map<string, Map<number, UgreenDirectoryPage>> =
    new Map<string, Map<number, UgreenDirectoryPage>>()
  private directoryRequests: Map<string, Promise<FileEntry[]>> = new Map<string, Promise<FileEntry[]>>()
  private directoryPageRequests: Map<string, Promise<UgreenDirectoryPage>> =
    new Map<string, Promise<UgreenDirectoryPage>>()
  private directoryIndexRequests: Map<string, Promise<DirectoryIndexedSnapshot>> =
    new Map<string, Promise<DirectoryIndexedSnapshot>>()
  private directoryTimelines: Map<string, DirectoryTimeline> = new Map<string, DirectoryTimeline>()
  private directoryTimelineFetchedAt: Map<string, number> = new Map<string, number>()
  private directoryRequestGenerations: Map<string, number> = new Map<string, number>()
  private thumbnailNormalizer: ThumbnailNormalizer = new ThumbnailNormalizer()
  private thumbnailCacheStore: ThumbnailCacheStore = new ThumbnailCacheStore()
  private thumbnailRequests: Map<string, Promise<string>> = new Map<string, Promise<string>>()
  private networkPolicy: NetworkPolicy = NetworkPolicy.shared()
  private meteredBackgroundRefreshAllowed: boolean = false
  private backgroundRefreshTimers: Record<string, number> = {}
  private cacheGeneration: number = 0

  initializeMetadata(context: Context): void {
    if (this.metadataInitPromise === null) {
      this.metadataInitPromise = this.directoryMetadataStore.initialize(context)
    }
  }

  async initializeThumbnailCache(context: Context): Promise<void> {
    await this.thumbnailCacheStore.initialize(context)
  }

  thumbnailCacheDirectory(): string {
    return this.thumbnailCacheStore.directoryPath()
  }

  async thumbnailCacheUsage(): Promise<number> {
    return await this.thumbnailCacheStore.usage()
  }

  async enforceThumbnailCacheLimit(maxBytes: number): Promise<void> {
    await this.thumbnailCacheStore.enforceLimit(maxBytes)
  }

  async clearThumbnailCache(): Promise<void> {
    await this.thumbnailCacheStore.clear()
  }

  /**
   * Synchronous thumbnail lookup for the file-surface render hot path. The
   * thumbnail store has already loaded and validated its index during cache
   * initialization, so this path does not perform filesystem I/O or network
   * work. A miss must fall through to prepareThumbnail().
   */
  cachedThumbnailFast(entry: FileEntry, profile: ThumbnailProfile = 'list'): string {
    if (entry.path.length === 0) {
      return ''
    }
    return this.thumbnailCacheStore.findFast(this.thumbnailIdentityKey(entry, profile))
  }

  setMeteredBackgroundRefreshAllowed(allowed: boolean): void {
    this.meteredBackgroundRefreshAllowed = allowed
  }

  setReconnectCredentials(username: string, password: string): void {
    this.client.setReconnectCredentials(username, password)
  }

  cacheScopeHash(): string {
    const scope = this.client.cacheScope()
    return scope.length > 0 ? CacheManager.hash('cache-scope-v2:' + scope) : ''
  }

  cacheKeyForFile(entry: FileEntry): string {
    return 'original-v3:' + this.cacheScopeHash() + ':' + entry.path + ':' +
      entry.size.toString() + ':' + entry.modifiedTime.toString()
  }

  /**
   * Stable identity shared by video streaming, disposable originals and the
   * durable Download route. Optional validators are included when the NAS
   * exposes them, while older endpoints continue to use size/mtime.
   */
  signatureForFile(entry: FileEntry): RemoteFileSignature {
    return new RemoteFileSignature(this.cacheScopeHash(), entry.path, entry.size,
      entry.modifiedTime, entry.etag, entry.checksum)
  }

  async resolve(linkId: string): Promise<string> {
    return await this.client.resolve(linkId)
  }

  async login(username: string, password: string): Promise<LoginResult> {
    const result = await this.client.login(username, password)
    this.clearDirectoryCache()
    return result
  }

  async verifyOtp(code: string, trustDevice: boolean): Promise<LoginResult> {
    const result = await this.client.verifyOtp(code, trustDevice)
    this.clearDirectoryCache()
    return result
  }

  logout(): void {
    this.client.clearSession()
    this.clearDirectoryCache()
  }

  async getRoot(): Promise<RootDirectory> {
    return await this.getRootWithCache(false)
  }

  async getRootWithCache(forceNetwork: boolean = false): Promise<RootDirectory> {
    const root = new RootDirectory()
    const result = await Promise.all([
      this.list('', 4, forceNetwork),
      this.list('', 3, forceNetwork)
    ])
    root.personal = result[0].filter((item: FileEntry) => item.isDirectory)
    root.shared = result[1].filter((item: FileEntry) => item.isDirectory)
    return root
  }

  async list(path: string, rootType: number, forceNetwork: boolean = false): Promise<FileEntry[]> {
    this.updateMetadataScope()
    const key = this.directoryCacheKey(path, rootType)
    const now = Date.now()
    const cached = this.directoryCache.get(key)
    if (!forceNetwork && cached !== undefined && cached.expiresAt > now) {
      cached.lastAccessAt = now
      return cached.entries.slice()
    }
    if (cached !== undefined) {
      this.directoryCache.delete(key)
    }

    const pending = this.directoryRequests.get(key)
    if (pending !== undefined) {
      return (await pending).slice()
    }

    if (!forceNetwork) {
      const persisted = await this.readPersistedDirectory(path, rootType)
      if (persisted !== null) {
        this.cacheDirectoryEntries(key, persisted.entries, Date.now())
        this.directoryTimelines.set(key, persisted.timeline)
        this.directoryTimelineFetchedAt.set(key, persisted.fetchedAt)
        this.scheduleBackgroundRefresh(path, rootType, key)
        return persisted.entries.slice()
      }
    }

    return (await this.fetchDirectory(path, rootType, key)).slice()
  }

  async listPage(path: string, rootType: number, pageIndex: number,
    forceNetwork: boolean = false): Promise<UgreenDirectoryPage> {
    this.updateMetadataScope()
    const key = this.directoryCacheKey(path, rootType)
    const pageKey = key + ':' + pageIndex.toString()
    const cachedPages = this.directoryPageCache.get(key)
    if (!forceNetwork && cachedPages !== undefined) {
      const cached = cachedPages.get(pageIndex)
      if (cached !== undefined) {
        return this.copyDirectoryPage(cached)
      }
    }
    if (!forceNetwork) {
      const persisted = await this.readPersistedDirectoryPage(path, rootType, pageIndex)
      if (persisted !== null) {
        this.cacheDirectoryPage(key, persisted)
        return this.copyDirectoryPage(persisted)
      }
    }
    const pending = this.directoryPageRequests.get(pageKey)
    if (pending !== undefined) {
      return this.copyDirectoryPage(await pending)
    }
    const generation = this.cacheGeneration
    const scope = this.metadataScope
    const request = this.requestDirectoryPage(path, rootType, pageIndex, key, generation, scope)
    this.directoryPageRequests.set(pageKey, request)
    try {
      return this.copyDirectoryPage(await request)
    } finally {
      if (this.directoryPageRequests.get(pageKey) === request) {
        this.directoryPageRequests.delete(pageKey)
      }
    }
  }

  /** Complete metadata index. This path never requests thumbnails or originals. */
  async ensureDirectoryIndex(path: string, rootType: number,
    forceNetwork: boolean = false): Promise<DirectoryIndexedSnapshot> {
    this.updateMetadataScope()
    const key = this.directoryCacheKey(path, rootType)
    const pending = this.directoryIndexRequests.get(key)
    if (pending !== undefined && !forceNetwork) {
      return await pending
    }
    const request = this.loadDirectoryIndex(path, rootType, key, forceNetwork)
    this.directoryIndexRequests.set(key, request)
    try {
      return await request
    } finally {
      if (this.directoryIndexRequests.get(key) === request) {
        this.directoryIndexRequests.delete(key)
      }
    }
  }

  async queryDirectory(query: DirectoryQuery, forceNetwork: boolean = false): Promise<FileEntry[]> {
    const snapshot = await this.ensureDirectoryIndex(query.path, query.rootType, forceNetwork)
    return DirectoryTimelinePolicy.query(snapshot.entries, query)
  }

  async getTimeline(path: string, rootType: number,
    forceNetwork: boolean = false): Promise<DirectoryTimeline> {
    const snapshot = await this.ensureDirectoryIndex(path, rootType, forceNetwork)
    return snapshot.timeline
  }

  async locateTimelineTime(path: string, rootType: number, targetTime: number,
    ascending: boolean): Promise<DirectoryTimelineLocation> {
    const snapshot = await this.ensureDirectoryIndex(path, rootType)
    const location = new DirectoryTimelineLocation()
    const dayStart = DirectoryTimelinePolicy.closestDay(snapshot.timeline, targetTime)
    if (dayStart <= 0) {
      return location
    }
    const query = new DirectoryQuery()
    query.path = path
    query.rootType = rootType
    query.sortKey = 'time'
    query.ascending = ascending
    const sorted = DirectoryTimelinePolicy.query(snapshot.entries, query)
    for (let index = 0; index < sorted.length; index++) {
      const entry = sorted[index]
      if (!entry.isDirectory && DirectoryTimelinePolicy.isImage(entry) &&
        DirectoryTimelinePolicy.localDayStart(entry.modifiedTime) === dayStart) {
        location.path = entry.path
        location.entryIndex = index
        location.dayStart = dayStart
        return location
      }
    }
    return location
  }

  async preindexPhotosDirectories(homePath: string): Promise<void> {
    if (homePath.length === 0 || this.networkPolicy.isMetered() ||
      this.networkPolicy.current() === 'offline') {
      return
    }
    const photosPath = this.joinRemotePath(homePath, 'Photos')
    try {
      const photos = await this.ensureDirectoryIndex(photosPath, 3)
      const candidates: FileEntry[] = []
      for (const entry of photos.entries) {
        if (entry.isDirectory &&
          (entry.childCount < 0 || entry.childCount >= DirectoryTimelinePolicy.MINIMUM_IMAGE_COUNT)) {
          candidates.push(entry)
        }
      }
      candidates.sort((left: FileEntry, right: FileEntry): number =>
        right.childCount - left.childCount)
      for (const entry of candidates) {
        if (this.networkPolicy.isMetered() || this.networkPolicy.current() === 'offline') {
          return
        }
        const candidatePath = entry.path.length > 0
          ? entry.path : this.joinRemotePath(photosPath, entry.name)
        try {
          await this.ensureDirectoryIndex(candidatePath, 3)
        } catch (_) {
          // Pre-indexing is opportunistic; one unreadable folder must not block the queue.
        }
      }
    } catch (_) {
      // Accounts without a Photos directory need no background work.
    }
  }

  /**
   * Search metadata starting at a directory. The existing directory-list API
   * is deliberately reused here because the remote search endpoint is not a
   * stable part of the client contract. Cached/persisted directories are
   * consumed first by list(), while uncached directories are loaded lazily.
   */
  async search(path: string, rootType: number, keyword: string,
    scope: RemoteSearchScope, onBatch?: RemoteSearchListener): Promise<FileEntry[]> {
    const query = keyword.trim().toLowerCase()
    if (query.length === 0) {
      return []
    }

    const results: FileEntry[] = []
    const pendingPaths: SearchDirectory[] = [{ path: path, rootType: rootType }]
    const visited: Record<string, boolean> = {}
    let nextIndex = 0
    const workerCount = this.networkPolicy.isMetered()
      ? 1 : (scope === 'descendants' ? 3 : 1)
    const worker = async (): Promise<void> => {
      while (true) {
        if (nextIndex >= pendingPaths.length) {
          return
        }
        const current = pendingPaths[nextIndex]
        nextIndex += 1
        const currentPath = current.path
        const currentRootType = current.rootType
        const currentKey = currentRootType.toString() + ':' + currentPath
        if (visited[currentKey] === true) {
          continue
        }
        visited[currentKey] = true

        let currentEntries: FileEntry[] = []
        try {
          currentEntries = await this.list(currentPath, currentRootType)
        } catch (_) {
          // A single inaccessible directory must not discard other matches.
          continue
        }

        const batch: FileEntry[] = []
        for (const entry of currentEntries) {
          if (entry.name.toLowerCase().includes(query)) {
            batch.push(entry)
            results.push(entry)
          }
          if (scope === 'descendants' && entry.isDirectory) {
            const childPath = entry.path.length > 0 ? entry.path :
              this.joinRemotePath(currentPath, entry.name)
            const childRootType = childPath.length > 0 ? 3 : currentRootType
            const childKey = childRootType.toString() + ':' + childPath
            if (visited[childKey] !== true) {
              pendingPaths.push({ path: childPath, rootType: childRootType })
            }
          }
        }
        if (batch.length > 0 && onBatch !== undefined) {
          onBatch(batch)
        }
      }
    }

    const workers: Promise<void>[] = []
    for (let index = 0; index < workerCount; index++) {
      workers.push(worker())
    }
    await Promise.all(workers)
    return results
  }

  async cachedDirectoryCount(path: string, rootType: number = 3): Promise<number> {
    this.updateMetadataScope()
    const key = this.directoryCacheKey(path, rootType)
    const now = Date.now()
    const cached = this.directoryCache.get(key)
    if (cached !== undefined && cached.expiresAt > now) {
      cached.lastAccessAt = now
      return cached.entries.length
    }
    if (cached !== undefined) {
      this.directoryCache.delete(key)
    }
    const persisted = await this.readPersistedDirectory(path, rootType)
    if (persisted === null) {
      return -1
    }
    this.cacheDirectoryEntries(key, persisted.entries, Date.now())
    return persisted.totalCount >= 0 ? persisted.totalCount : persisted.entries.length
  }

  invalidateDirectory(path: string, rootType: number): void {
    this.cacheGeneration += 1
    const key = this.directoryCacheKey(path, rootType)
    const timer = this.backgroundRefreshTimers[key]
    if (timer > 0) {
      clearTimeout(timer)
    }
    this.backgroundRefreshTimers[key] = 0
    this.directoryCache.delete(key)
    this.directoryPageCache.delete(key)
    this.directoryRequests.delete(key)
    this.directoryRequestGenerations.delete(key)
    const pendingPageKeys = Array.from(this.directoryPageRequests.keys())
    for (const pageKey of pendingPageKeys) {
      if (pageKey.indexOf(key + ':') === 0) {
        this.directoryPageRequests.delete(pageKey)
      }
    }
    this.directoryIndexRequests.delete(key)
    this.directoryTimelines.delete(key)
    this.directoryTimelineFetchedAt.delete(key)
    if (this.metadataInitPromise !== null && this.metadataScope.length > 0) {
      const scope = this.metadataScope
      this.metadataInitPromise.then((): Promise<void> =>
        this.directoryMetadataStore.remove(scope, path, rootType)).catch((): void => {})
    }
  }

  clearDirectoryCache(): void {
    this.cacheGeneration += 1
    this.directoryCache.clear()
    this.directoryPageCache.clear()
    this.directoryRequests.clear()
    this.directoryRequestGenerations.clear()
    this.directoryPageRequests.clear()
    this.directoryIndexRequests.clear()
    this.directoryTimelines.clear()
    this.directoryTimelineFetchedAt.clear()
    this.backgroundRefreshTimers = {}
  }

  async clearPersistentDirectoryCache(): Promise<void> {
    this.clearDirectoryCache()
    if (this.metadataInitPromise === null) {
      return
    }
    await this.metadataInitPromise
    await this.directoryMetadataStore.clear(this.metadataScope)
  }

  private async readPersistedDirectory(path: string, rootType: number): Promise<DirectoryMetadataSnapshot | null> {
    if (this.metadataInitPromise === null || this.metadataScope.length === 0) {
      return null
    }
    await this.metadataInitPromise
    return await this.directoryMetadataStore.read(this.metadataScope, path, rootType)
  }

  private async readPersistedDirectoryPage(path: string, rootType: number,
    pageIndex: number): Promise<UgreenDirectoryPage | null> {
    if (this.metadataInitPromise === null || this.metadataScope.length === 0) {
      return null
    }
    await this.metadataInitPromise
    const page: DirectoryMetadataPage | null = await this.directoryMetadataStore.readPage(
      this.metadataScope, path, rootType, pageIndex)
    if (page === null) {
      return null
    }
    return {
      pageIndex: page.pageIndex,
      entries: page.entries,
      totalCount: page.totalCount,
      hasMore: page.hasMore
    }
  }

  private fetchDirectory(path: string, rootType: number, key: string): Promise<FileEntry[]> {
    const generation = this.cacheGeneration
    const scope = this.metadataScope
    const request = this.requestDirectory(path, rootType, key, generation, scope)
    this.directoryRequests.set(key, request)
    this.directoryRequestGenerations.set(key, generation)
    return request
  }

  private async requestDirectory(path: string, rootType: number, key: string,
    generation: number, scope: string): Promise<FileEntry[]> {
    try {
      const pages = await this.client.listPages(path, rootType)
      const entries: FileEntry[] = []
      const pageEntries: FileEntry[][] = []
      let totalCount = -1
      const complete = pages.length > 0 && !pages[pages.length - 1].hasMore
      for (const page of pages) {
        pageEntries.push(page.entries)
        for (const entry of page.entries) {
          entries.push(entry)
        }
        if (page.totalCount >= 0) {
          totalCount = page.totalCount
        }
      }
      const timeline = DirectoryTimelinePolicy.build(entries, complete)
      const contentSignature = DirectoryTimelinePolicy.contentSignature(entries)
      if (generation === this.cacheGeneration && scope === this.metadataScope) {
        const fetchedAt = Date.now()
        this.cacheDirectoryEntries(key, entries, Date.now(), contentSignature)
        this.directoryTimelines.set(key, timeline)
        this.directoryTimelineFetchedAt.set(key, fetchedAt)
        if (scope.length > 0 && complete) {
          this.directoryMetadataStore.saveSnapshot(scope, path, rootType, pageEntries, totalCount,
            timeline)
        }
      }
      return entries
    } finally {
      if (this.directoryRequestGenerations.get(key) === generation) {
        this.directoryRequests.delete(key)
        this.directoryRequestGenerations.delete(key)
      }
    }
  }

  private async requestDirectoryPage(path: string, rootType: number, pageIndex: number,
    key: string, generation: number, scope: string): Promise<UgreenDirectoryPage> {
    const page = await this.client.listPage(path, rootType, pageIndex)
    if (generation === this.cacheGeneration && scope === this.metadataScope) {
      this.cacheDirectoryPage(key, page)
      if (scope.length > 0) {
        await this.directoryMetadataStore.savePage(scope, path, rootType, page.pageIndex,
          page.entries, page.totalCount)
      }
    }
    return page
  }

  private cacheDirectoryPage(key: string, page: UgreenDirectoryPage): void {
    let pages = this.directoryPageCache.get(key)
    if (pages === undefined) {
      pages = new Map<number, UgreenDirectoryPage>()
      this.directoryPageCache.set(key, pages)
    }
    pages.set(page.pageIndex, this.copyDirectoryPage(page))
    const allEntries: FileEntry[] = []
    const seen: Record<string, boolean> = {}
    const indexes = Array.from(pages.keys()).sort((left: number, right: number): number => left - right)
    for (const index of indexes) {
      const cached = pages.get(index)
      if (cached === undefined) {
        continue
      }
      for (const entry of cached.entries) {
        if (entry.path.length === 0 || seen[entry.path] === true) {
          continue
        }
        seen[entry.path] = true
        allEntries.push(entry)
      }
    }
    this.cacheDirectoryEntries(key, allEntries, Date.now())
  }

  private copyDirectoryPage(page: UgreenDirectoryPage): UgreenDirectoryPage {
    return {
      pageIndex: page.pageIndex,
      entries: page.entries.slice(),
      totalCount: page.totalCount,
      hasMore: page.hasMore
    }
  }

  private cacheDirectoryEntries(key: string, entries: FileEntry[], timestamp: number,
    contentSignature: string = ''): void {
    this.directoryCache.set(key, {
      entries: entries.slice(),
      expiresAt: timestamp + UgreenRemoteRepository.DIRECTORY_CACHE_TTL_MS,
      lastAccessAt: timestamp,
      contentSignature: contentSignature.length > 0
        ? contentSignature : DirectoryTimelinePolicy.contentSignature(entries)
    })
    this.trimDirectoryCache()
  }

  private scheduleBackgroundRefresh(path: string, rootType: number, key: string): void {
    if (this.backgroundRefreshTimers[key] > 0 || this.directoryRequests.has(key)) {
      return
    }
    const scope = this.metadataScope
    const generation = this.cacheGeneration
    this.backgroundRefreshTimers[key] = setTimeout((): void => {
      this.backgroundRefreshTimers[key] = 0
      if (generation !== this.cacheGeneration || scope !== this.metadataScope || this.directoryRequests.has(key)) {
        return
      }
      if (this.networkPolicy.isMetered() && !this.meteredBackgroundRefreshAllowed) {
        return
      }
      this.fetchDirectory(path, rootType, key).catch((): FileEntry[] => [])
    }, 600)
  }

  private updateMetadataScope(): void {
    const rawScope = this.client.cacheScope()
    const nextScope = rawScope.length > 0
      ? CacheManager.hash('metadata-scope-v2:' + rawScope) : ''
    if (nextScope.length === 0 || nextScope === this.metadataScope) {
      return
    }
    this.metadataScope = nextScope
    this.cacheGeneration += 1
    this.directoryCache.clear()
    this.directoryPageCache.clear()
    this.directoryRequests.clear()
    this.directoryRequestGenerations.clear()
    this.directoryPageRequests.clear()
    this.directoryIndexRequests.clear()
    this.directoryTimelines.clear()
    this.directoryTimelineFetchedAt.clear()
    this.backgroundRefreshTimers = {}
  }

  private directoryCacheKey(path: string, rootType: number): string {
    return rootType.toString() + ':' + path.trim().replace(/\/{2,}/g, '/')
  }

  private joinRemotePath(parent: string, name: string): string {
    if (parent.length === 0) {
      return '/' + name
    }
    return parent.replace(/\/+$/, '') + '/' + name
  }

  private trimDirectoryCache(): void {
    while (this.directoryCache.size > UgreenRemoteRepository.DIRECTORY_CACHE_MAX_ENTRIES) {
      let oldestKey = ''
      let oldestAccess = Number.MAX_SAFE_INTEGER
      this.directoryCache.forEach((item: DirectoryCacheItem, key: string): void => {
        if (item.lastAccessAt < oldestAccess) {
          oldestAccess = item.lastAccessAt
          oldestKey = key
        }
      })
      if (oldestKey.length === 0) {
        return
      }
      this.directoryCache.delete(oldestKey)
      this.directoryTimelines.delete(oldestKey)
      this.directoryTimelineFetchedAt.delete(oldestKey)
    }
  }

  private async loadDirectoryIndex(path: string, rootType: number, key: string,
    forceNetwork: boolean): Promise<DirectoryIndexedSnapshot> {
    if (!forceNetwork) {
      const cached = this.directoryCache.get(key)
      const cachedTimeline = this.directoryTimelines.get(key)
      if (cached !== undefined && cachedTimeline !== undefined && cachedTimeline.complete) {
        const snapshot = new DirectoryIndexedSnapshot()
        snapshot.entries = cached.entries.slice()
        snapshot.fetchedAt = this.directoryTimelineFetchedAt.get(key) ?? 0
        snapshot.totalCount = cached.entries.length
        snapshot.timeline = cachedTimeline
        snapshot.contentSignature = cached.contentSignature
        return snapshot
      }
      const persisted = await this.readPersistedDirectory(path, rootType)
      if (persisted !== null) {
        this.cacheDirectoryEntries(key, persisted.entries, Date.now())
        this.directoryTimelines.set(key, persisted.timeline)
        this.directoryTimelineFetchedAt.set(key, persisted.fetchedAt)
        const snapshot = new DirectoryIndexedSnapshot()
        snapshot.entries = persisted.entries.slice()
        snapshot.fetchedAt = persisted.fetchedAt
        snapshot.totalCount = persisted.totalCount
        snapshot.timeline = persisted.timeline
        snapshot.contentSignature = persisted.contentSignature
        return snapshot
      }
    }

    const running = this.directoryRequests.get(key)
    const entries = running !== undefined
      ? await running : await this.fetchDirectory(path, rootType, key)
    const timeline = this.directoryTimelines.get(key) ??
      DirectoryTimelinePolicy.build(entries, false)
    const snapshot = new DirectoryIndexedSnapshot()
    snapshot.entries = entries.slice()
    snapshot.fetchedAt = this.directoryTimelineFetchedAt.get(key) ?? Date.now()
    snapshot.totalCount = entries.length
    snapshot.timeline = timeline
    snapshot.contentSignature = DirectoryTimelinePolicy.contentSignature(entries)
    return snapshot
  }

  async download(entry: FileEntry, filesDirectory: string, maxBytes: number,
    onProgress?: BinaryProgressListener, shouldContinue?: () => boolean): Promise<string> {
    return await this.client.withReconnect(() =>
      this.downloadOnce(entry, filesDirectory, maxBytes, onProgress, shouldContinue))
  }

  /**
   * Returns a fresh, authenticated download URL for the persistent user
   * download queue. The URL/token is intentionally not persisted because the
   * NAS gateway may expire it while a task is paused or the app is closed.
   */
  async downloadDescriptor(path: string): Promise<DownloadDescriptor> {
    return await this.client.withReconnect(() => this.client.download(path))
  }

  /** Authenticated mediaPlayer source for AVPlayer Range streaming. */
  async mediaPlayerDescriptor(entry: FileEntry): Promise<DownloadDescriptor> {
    return await this.client.mediaPlayerDescriptor(entry)
  }

  /**
   * Prepare the server-side HLS source used by the web video viewer.  Older
   * NAS firmware may reject this when its transcode worker is unavailable;
   * callers should fall back to mediaPlayerDescriptor in that case.
   */
  async streamDescriptor(entry: FileEntry): Promise<DownloadDescriptor> {
    return await this.client.streamDescriptor(entry)
  }

  async closeStreamTask(taskId: string, sourceType: number = 1): Promise<void> {
    await this.client.closeStreamTask(taskId, sourceType)
  }

  private async downloadOnce(entry: FileEntry, filesDirectory: string, maxBytes: number,
    onProgress?: BinaryProgressListener, shouldContinue?: () => boolean): Promise<string> {
    const descriptor = await this.client.download(entry.path)
    if (descriptor.size <= 0 && entry.size > 0) {
      descriptor.size = entry.size
    }
    if (descriptor.etag.length === 0) {
      descriptor.etag = entry.etag
    }
    if (descriptor.checksum.length === 0) {
      descriptor.checksum = entry.checksum
    }
    return await this.downloadManager.download(descriptor, filesDirectory, maxBytes,
      this.cacheKeyForFile(entry), onProgress, shouldContinue)
  }

  async prepareThumbnail(entry: FileEntry, cacheDirectory: string, maxBytes: number,
    profile: ThumbnailProfile = 'list'): Promise<string> {
    return await this.client.withReconnect(() =>
      this.prepareThumbnailOnce(entry, cacheDirectory, maxBytes, profile))
  }

  private async prepareThumbnailOnce(entry: FileEntry, cacheDirectory: string, maxBytes: number,
    profile: ThumbnailProfile = 'list'): Promise<string> {
    const identityKey = this.thumbnailIdentityKey(entry, profile)
    const identityFileName = entry.name + '.thumbnail'
    const directPath = await this.thumbnailCacheStore.find(identityKey, identityFileName)
    if (directPath.length > 0) {
      return directPath
    }

    const descriptors = await this.client.thumbnailCandidates(entry)

    // Resolve every persistent candidate before starting any network request.
    // The thumbnail cache is deliberately isolated from the disposable
    // original-file cache and never reads legacy cacheDir previews.
    for (const descriptor of descriptors) {
      if (descriptor.url.length === 0) {
        continue
      }
      const cacheKey = this.thumbnailCacheKey(entry, descriptor.url, profile)
      // Thumbnail bytes are normalized by profile. Do not fall back to a
      // legacy unkeyed thumbnail because it may have a different physical
      // aspect ratio or decode size.
      const indexedPath = await this.thumbnailCacheStore.find(cacheKey, descriptor.fileName)
      if (indexedPath.length > 0) {
        await this.thumbnailCacheStore.register(identityKey, indexedPath)
        return indexedPath
      }
      const cachedPath = CacheManager.cachePath(cacheDirectory, descriptor.fileName, cacheKey)
      if (CacheManager.exists(cachedPath)) {
        await this.thumbnailCacheStore.register(cacheKey, cachedPath)
        await this.thumbnailCacheStore.register(identityKey, cachedPath)
        return cachedPath
      }
    }

    for (const descriptor of descriptors) {
      if (descriptor.url.length === 0) {
        continue
      }
      const cacheKey = this.thumbnailCacheKey(entry, descriptor.url, profile)
      const pending = this.thumbnailRequests.get(cacheKey)
      if (pending !== undefined) {
        try {
          const pendingPath = await pending
          if (pendingPath.length > 0) {
            return pendingPath
          }
        } catch (_) {
          // Try the next candidate route below.
        }
        continue
      }
      const request = this.fetchAndNormalizeThumbnail(entry, descriptor.url, descriptor.headers,
        descriptor.fileName, cacheDirectory, maxBytes, profile, cacheKey)
      this.thumbnailRequests.set(cacheKey, request)
      try {
        const preparedPath = await request
        if (preparedPath.length > 0) {
          await this.thumbnailCacheStore.register(cacheKey, preparedPath)
          await this.thumbnailCacheStore.register(identityKey, preparedPath)
          return preparedPath
        }
      } catch (error) {
        console.warn('[UgreenThumbnail] route failed: ' + descriptor.url + ': ' + JSON.stringify(error))
      } finally {
        if (this.thumbnailRequests.get(cacheKey) === request) {
          this.thumbnailRequests.delete(cacheKey)
        }
      }
    }
    return ''
  }

  private thumbnailCacheKey(entry: FileEntry, url: string, profile: ThumbnailProfile): string {
    // Ignore short-lived query signatures in the cache key. The NAS path,
    // file metadata, thumbnail variant and source route identify content.
    const stableUrl = url.split('?')[0]
    return 'thumbnail-v3:' + this.cacheScopeHash() + ':' + profile + ':' + entry.path + ':' +
      entry.modifiedTime.toString() + ':' + entry.size.toString() + ':' + stableUrl
  }

  private thumbnailIdentityKey(entry: FileEntry, profile: ThumbnailProfile): string {
    return 'thumbnail-v4:' + this.cacheScopeHash() + ':' + profile + ':' + entry.path + ':' +
      entry.modifiedTime.toString() + ':' + entry.size.toString()
  }

  private async fetchAndNormalizeThumbnail(entry: FileEntry, url: string,
    headers: Record<string, string>, fileName: string, cacheDirectory: string,
    maxBytes: number, profile: ThumbnailProfile, cacheKey: string): Promise<string> {
    const bytes = await this.transport.requestBinary(url, headers)
    const prepared = await this.thumbnailNormalizer.prepare(bytes, entry.path, fileName,
      cacheDirectory, maxBytes, profile, cacheKey)
    return prepared === null ? '' : prepared.path
  }

  async rename(entry: FileEntry, newName: string): Promise<void> {
    await this.client.rename(entry.path, newName)
    await this.clearDirectoryMetadataAfterMutation()
  }

  async copy(paths: string[], targetPath: string): Promise<void> {
    await this.client.copy(paths, targetPath)
    await this.clearDirectoryMetadataAfterMutation()
  }

  async move(paths: string[], targetPath: string): Promise<void> {
    await this.client.move(paths, targetPath)
    await this.clearDirectoryMetadataAfterMutation()
  }

  async createFolder(path: string): Promise<void> {
    await this.client.createFolder(path)
    await this.clearDirectoryMetadataAfterMutation()
  }

  async prepareUpload(dir: string, name: string, uuid: string, size: number,
    changed: number): Promise<boolean> {
    return this.client.prepareUpload(dir, name, uuid, size, changed)
  }
  async uploadOffset(dir: string, uuid: string, size: number): Promise<number> {
    return this.client.uploadOffset(dir, uuid, size)
  }
  async uploadChunk(dir: string, name: string, uuid: string, size: number,
    changed: number, offset: number, bytes: ArrayBuffer): Promise<void> {
    await this.client.uploadChunk(dir, name, uuid, size, changed, offset, bytes)
    if (offset + bytes.byteLength >= size) { await this.clearDirectoryMetadataAfterMutation() }
  }
  async removeUploadTemporary(dir: string, uuid: string): Promise<void> {
    await this.client.removeUploadTemporary(dir, uuid)
  }

  async trash(entry: FileEntry, parentPath: string = '', rootType: number = 3): Promise<void> {
    await this.client.trash(entry.path)
    // Deleting one entry only invalidates its parent directory. Clearing the
    // complete account metadata database here made the UI wait for unrelated
    // directories and was especially expensive for large photo libraries.
    this.invalidateDirectory(parentPath, rootType)
  }

  // ── Recycle bin ──────────────────────────────────────────────────────────
  //
  // UGOS keeps deleted items in a hidden `<folder>/#recycle` repository, one
  // per first-level folder — Samba's standard repository name, not a
  // localised one. The repository mirrors the original tree, so a recycled
  // item's path is `<share>/#recycle/<relative path>` and its original
  // location is recovered by dropping that single segment. Names and sizes
  // survive verbatim (measured against a live NAS), which is what makes a
  // restore possible without keeping a side table of our own.
  //
  // The repository is absent from ordinary listings, so nothing else in the
  // app can stumble into it; it is only ever reached by explicit path.

  /** `<share>/#recycle`, or an empty string when there is no share to qualify. */
  static recycleRepositoryPath(sharePath: string): string {
    const clean = sharePath.replace(/\/+$/, '')
    return clean.length > 0 ? clean + '/#recycle' : ''
  }

  /**
   * Where a recycled item came from, or an empty string when `itemPath` is not
   * inside `sharePath`'s repository.
   */
  static originalPathOfRecycledItem(itemPath: string, sharePath: string): string {
    const repository = UgreenRemoteRepository.recycleRepositoryPath(sharePath)
    if (repository.length === 0) {
      return ''
    }
    const prefix = repository + '/'
    if (!itemPath.startsWith(prefix)) {
      return ''
    }
    return sharePath.replace(/\/+$/, '') + '/' + itemPath.slice(prefix.length)
  }

  /**
   * Lists one level of a share's recycle bin — the direct children of
   * `directoryPath`, which is itself a path inside `<share>/#recycle`.
   *
   * It deliberately never walks the mirror tree. An earlier version flattened
   * the whole tree into one leaf list, which answered "what did I delete"
   * directly but read as a second, structureless file browser. The page layers
   * directory navigation on top of repeated single-level reads instead, so the
   * user gets the same drill-down they already know from the file manager.
   *
   * Top level: `listRecycleChildren(share, recycleRepositoryPath(share))`.
   * A sub-folder: `listRecycleChildren(share, <entry>.path)`.
   *
   * Failures propagate on purpose. A shared folder whose bin is
   * administrator-only answers `Access not allowed`, and whether that deserves
   * a "could not read" note or just an empty state depends on which level is
   * being shown — a decision only the caller can make.
   */
  async listRecycleChildren(sharePath: string, directoryPath: string): Promise<FileEntry[]> {
    const share = sharePath.replace(/\/+$/, '')
    const children = await this.client.list(directoryPath, UgreenRemoteRepository.RECYCLE_ROOT_TYPE)
    for (const child of children) {
      // Stamped once here so restore/purge can strip the repository segment
      // and rebuild the original location without another lookup.
      child.recycleSharePath = share
    }
    return children
  }

  /**
   * Moves one recycled item back to where it was deleted from.
   *
   * The fast path is a single move — the directory it came from almost always
   * still exists. Only when that fails do we rebuild the directory chain
   * inside the share and retry, so the common case stays one request while
   * items whose parent folder was itself deleted are still recoverable.
   */
  async restoreFromRecycle(item: FileEntry, sharePath: string): Promise<void> {
    const original = UgreenRemoteRepository.originalPathOfRecycledItem(item.path, sharePath)
    const trimmed = original.replace(/\/+$/, '')
    const separator = trimmed.lastIndexOf('/')
    if (original.length === 0 || separator <= 0) {
      throw new Error('无法确定该项目的原始位置')
    }
    const targetDirectory = trimmed.slice(0, separator)
    try {
      await this.client.move([item.path], targetDirectory)
    } catch (_) {
      await this.ensureShareDirectoryChain(sharePath, targetDirectory)
      await this.client.move([item.path], targetDirectory)
    }
    await this.clearDirectoryMetadataAfterMutation()
    this.invalidateDirectory(sharePath, UgreenRemoteRepository.RECYCLE_ROOT_TYPE)
  }

  /** Permanently deletes recycled items. There is no undo. */
  async purgeRecycle(paths: string[]): Promise<void> {
    if (paths.length === 0) {
      return
    }
    await this.client.deleteForever(paths)
    await this.clearDirectoryMetadataAfterMutation()
  }

  /**
   * Creates `targetDirectory` and any missing ancestors below `sharePath`.
   *
   * "Already exists" is an expected outcome while rebuilding a chain, so those
   * failures are swallowed on purpose — the follow-up move in the caller is
   * the real test of whether the directory is usable.
   */
  private async ensureShareDirectoryChain(sharePath: string, targetDirectory: string): Promise<void> {
    const share = sharePath.replace(/\/+$/, '')
    const target = targetDirectory.replace(/\/+$/, '')
    if (share.length === 0 || !target.startsWith(share + '/')) {
      // Never create anything outside the share the item belongs to.
      return
    }
    const relative = target.slice(share.length + 1)
    let current = share
    for (const segment of relative.split('/')) {
      if (segment.length === 0) {
        continue
      }
      current = current + '/' + segment
      try {
        await this.client.createFolder(current)
      } catch (_) {
        // Already present, or created concurrently. Keep walking.
      }
    }
  }

  private async clearDirectoryMetadataAfterMutation(): Promise<void> {
    this.clearDirectoryCache()
    if (this.metadataInitPromise === null || this.metadataScope.length === 0) {
      return
    }
    await this.metadataInitPromise
    await this.directoryMetadataStore.clear(this.metadataScope)
  }
}

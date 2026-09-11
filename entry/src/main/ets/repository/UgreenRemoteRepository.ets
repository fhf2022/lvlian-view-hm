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

interface DirectoryCacheItem {
  entries: FileEntry[]
  expiresAt: number
  lastAccessAt: number
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
    this.directoryCache.delete(key)
    this.directoryPageCache.delete(key)
    this.directoryRequests.delete(key)
    this.directoryRequestGenerations.delete(key)
  }

  clearDirectoryCache(): void {
    this.cacheGeneration += 1
    this.directoryCache.clear()
    this.directoryPageCache.clear()
    this.directoryRequests.clear()
    this.directoryRequestGenerations.clear()
    this.directoryPageRequests.clear()
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
      let complete = pages.length > 0
      for (const page of pages) {
        pageEntries.push(page.entries)
        for (const entry of page.entries) {
          entries.push(entry)
        }
        if (page.totalCount >= 0) {
          totalCount = page.totalCount
        }
        if (page.hasMore) {
          complete = false
        }
      }
      if (generation === this.cacheGeneration && scope === this.metadataScope) {
        this.cacheDirectoryEntries(key, entries, Date.now())
        if (scope.length > 0 && complete) {
          this.directoryMetadataStore.saveSnapshot(scope, path, rootType, pageEntries, totalCount)
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

  private cacheDirectoryEntries(key: string, entries: FileEntry[], timestamp: number): void {
    this.directoryCache.set(key, {
      entries: entries.slice(),
      expiresAt: timestamp + UgreenRemoteRepository.DIRECTORY_CACHE_TTL_MS,
      lastAccessAt: timestamp
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
    }
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
        return indexedPath
      }
      const cachedPath = CacheManager.cachePath(cacheDirectory, descriptor.fileName, cacheKey)
      if (CacheManager.exists(cachedPath)) {
        await this.thumbnailCacheStore.register(cacheKey, cachedPath)
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
    this.clearDirectoryCache()
  }

  async copy(paths: string[], targetPath: string): Promise<void> {
    await this.client.copy(paths, targetPath)
    this.clearDirectoryCache()
  }

  async move(paths: string[], targetPath: string): Promise<void> {
    await this.client.move(paths, targetPath)
    this.clearDirectoryCache()
  }

  async createFolder(path: string): Promise<void> {
    await this.client.createFolder(path)
    this.clearDirectoryCache()
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
    if (offset + bytes.byteLength >= size) { this.clearDirectoryCache() }
  }
  async removeUploadTemporary(dir: string, uuid: string): Promise<void> {
    await this.client.removeUploadTemporary(dir, uuid)
  }

  async trash(entry: FileEntry): Promise<void> {
    await this.client.trash(entry.path)
    this.clearDirectoryCache()
  }
}

import { Context } from '@kit.AbilityKit'
import { fileIo } from '@kit.CoreFileKit'
import { CacheManager, CachedFile } from '../download/CacheManager'
import { JsonObject } from '../core/network/HttpTypes'

interface ThumbnailCacheItem {
  path: string
  lastAccessAt: number
  size: number
}

interface ThumbnailCacheDocument {
  version: number
  items: Record<string, ThumbnailCacheItem>
}

interface ThumbnailPhysicalFile {
  path: string
  size: number
  modifiedTime: number
  lastAccessAt: number
}

/**
 * Persistent index and storage boundary for list thumbnails.
 *
 * Thumbnails are deliberately kept outside cacheDir. cacheDir is disposable
 * and HarmonyOS may reclaim it without asking the application. This store
 * uses the private files directory and keeps its own bounded LRU directory.
 */
export class ThumbnailCacheStore {
  static readonly DEFAULT_LIMIT_BYTES: number = 512 * 1024 * 1024
  private static readonly DIRECTORY_NAME: string = 'ugreen-thumbnail-cache'
  private static readonly INDEX_FILE_NAME: string = 'ugreen-thumbnail-index.json'
  // Each physical thumbnail can carry a route key plus a stable identity
  // alias. Keep the original 20,000-file capacity rather than counting both
  // references as separate cached images.
  private static readonly MAX_INDEX_ITEMS: number = 40000

  private directory: string = ''
  private indexPath: string = ''
  private items: Map<string, ThumbnailCacheItem> = new Map()
  private initPromise: Promise<void> | null = null
  private writeQueue: Promise<void> = Promise.resolve()
  private persistTimer: number = 0
  private persistDirty: boolean = false
  private accessPersistTimer: number = 0
  private accessPersistDirty: boolean = false
  private itemCount: number = 0
  private keysByPath: Map<string, Set<string>> = new Map()
  private removed = (path: string): void => {
    const keys = this.keysByPath.get(path)
    if (keys === undefined) { return }
    this.removeKeys(Array.from(keys))
    this.schedulePersist()
  }

  async initialize(context: Context): Promise<void> {
    if (this.initPromise === null) {
      CacheManager.onRemoved(this.removed)
      this.initPromise = this.open(context)
    }
    await this.initPromise
  }

  directoryPath(): string {
    return this.directory
  }

  /**
   * Hot-path lookup for rendering. The index is loaded and validated during
   * initialize(), so this method does not stat files, read JSON, or await.
   * That lets a recycled list item use a durable thumbnail URI in its first
   * render pass instead of briefly entering the placeholder state.
   */
  findFast(cacheKey: string): string {
    if (cacheKey.length === 0 || this.directory.length === 0) {
      return ''
    }
    const indexed = this.items.get(cacheKey)
    if (indexed === undefined) {
      return ''
    }
    this.touchIndexedItem(indexed)
    return indexed.path
  }

  async find(cacheKey: string, fileName: string): Promise<string> {
    if (cacheKey.length === 0 || fileName.length === 0 || this.directory.length === 0) {
      return ''
    }
    const indexed = this.items.get(cacheKey)
    if (indexed !== undefined && CacheManager.exists(indexed.path)) {
      // Keep logical access time in memory. A later cache write or limit
      // maintenance persists it; a read hit must not serialize the complete
      // index while the user is scrolling.
      this.touchIndexedItem(indexed)
      return indexed.path
    }

    // Recover an entry written before the index write completed, or after an
    // index file was partially lost. The path is deterministic from the key.
    const derivedPath = CacheManager.cachePath(this.directory, fileName, cacheKey)
    if (CacheManager.exists(derivedPath)) {
      await this.register(cacheKey, derivedPath)
      return derivedPath
    }

    if (indexed !== undefined) {
      this.removeKeys([cacheKey])
      await this.persist()
    }
    return ''
  }

  async register(cacheKey: string, path: string): Promise<void> {
    if (cacheKey.length === 0 || path.length === 0) {
      return
    }
    let size = 0
    try {
      size = fileIo.statSync(path).size
    } catch (_) {
      return
    }
    const previous = this.items.get(cacheKey)
    const isNewKey = previous === undefined || previous.path !== path
    if (previous !== undefined && previous.path !== path) { this.removeKeys([cacheKey]) }
    this.items.set(cacheKey, {
      path: path,
      lastAccessAt: Date.now(),
      size: size
    })
    if (isNewKey) {
      this.itemCount += 1
    }
    this.indexPathKey(path, cacheKey)
    await this.trimIndex()
    this.schedulePersist()
  }

  async enforceLimit(maxBytes: number): Promise<void> {
    if (this.directory.length === 0) {
      return
    }
    await CacheManager.runSerialized(async (): Promise<void> => {
      await this.enforceLimitNow(maxBytes)
    })
    await this.flushPersist()
  }

  async usage(): Promise<number> {
    if (this.directory.length === 0) {
      return 0
    }
    return await CacheManager.usage(this.directory)
  }

  async clear(): Promise<void> {
    if (this.directory.length > 0) {
      await CacheManager.clear(this.directory)
    }
    this.items.clear()
    this.itemCount = 0
    this.keysByPath.clear()
    await this.flushPersist()
  }

  private async enforceLimitNow(maxBytes: number): Promise<void> {
    if (maxBytes <= 0) {
      return
    }
    const indexedAccess: Record<string, number> = {}
    for (const key of Array.from(this.items.keys())) {
      const item = this.items.get(key)
      if (item === undefined) { continue }
      const previous = indexedAccess[item.path]
      indexedAccess[item.path] = previous === undefined
        ? item.lastAccessAt : Math.max(previous, item.lastAccessAt)
    }
    const files = await this.listPhysicalFiles()
    const present = new Set<string>(files.map((file: ThumbnailPhysicalFile): string => file.path))
    for (const path of Array.from(this.keysByPath.keys())) {
      if (!present.has(path)) { CacheManager.reportRemoved(path) }
    }
    let total = 0
    for (const file of files) {
      total += file.size
      const indexed = indexedAccess[file.path]
      file.lastAccessAt = indexed === undefined ? file.modifiedTime : indexed
    }
    files.sort((left: ThumbnailPhysicalFile, right: ThumbnailPhysicalFile): number => {
      return left.lastAccessAt - right.lastAccessAt
    })
    const removedPaths = new Set<string>()
    for (const file of files) {
      if (total <= maxBytes) {
        break
      }
      try {
        await fileIo.unlink(file.path)
        CacheManager.reportRemoved(file.path)
        CacheManager.invalidateThumbnailInventory()
        removedPaths.add(file.path)
        total = Math.max(0, total - file.size)
        this.removeKeysForPath(file.path)
      } catch (_) {
        // A single reclaimed or concurrently removed thumbnail must not stop
        // the remaining LRU candidates from being considered.
      }
    }
    CacheManager.primeThumbnailInventory(this.directory,
      files.filter((file: ThumbnailPhysicalFile): boolean => !removedPaths.has(file.path))
        .map((file: ThumbnailPhysicalFile): CachedFile => {
          return { path: file.path, size: file.size, modifiedTime: file.modifiedTime / 1000 }
        }))
  }

  private async listPhysicalFiles(): Promise<ThumbnailPhysicalFile[]> {
    const result: ThumbnailPhysicalFile[] = []
    let names: string[] = []
    try {
      names = await fileIo.listFile(this.directory)
    } catch (_) {
      return result
    }
    for (let offset = 0; offset < names.length; offset += 8) {
      const batch = await Promise.all(names.slice(offset, offset + 8).map(
        async (name: string): Promise<ThumbnailPhysicalFile | null> => {
          const path = this.directory + '/' + name
          try {
            const stat = await fileIo.stat(path)
            return stat.isFile() ? { path: path, size: stat.size,
              modifiedTime: stat.mtime * 1000, lastAccessAt: stat.mtime * 1000 } : null
          } catch (_) { return null }
        }))
      for (const file of batch) { if (file !== null) { result.push(file) } }
    }
    return result
  }

  private removeKeysForPath(path: string): void {
    const keys = this.keysByPath.get(path)
    if (keys !== undefined) { this.removeKeys(Array.from(keys)) }
  }

  private touchIndexedItem(item: ThumbnailCacheItem): void {
    const now = Date.now()
    item.lastAccessAt = now
    // Persist access order occasionally. Never write the whole index for
    // every Image build; continuous scrolling should remain read-only.
    this.accessPersistDirty = true
    if (this.accessPersistTimer <= 0) {
      this.accessPersistTimer = setTimeout((): void => {
        this.accessPersistTimer = 0
        if (!this.accessPersistDirty) {
          return
        }
        this.accessPersistDirty = false
        this.persist().catch((): void => {})
      }, 5000)
    }
  }

  private async open(context: Context): Promise<void> {
    const baseDirectory = context.filesDir.replace(/\/+$/, '')
    this.directory = baseDirectory + '/' + ThumbnailCacheStore.DIRECTORY_NAME
    this.indexPath = baseDirectory + '/' + ThumbnailCacheStore.INDEX_FILE_NAME
    try {
      fileIo.mkdirSync(this.directory, true)
    } catch (_) {
      // The directory normally already exists. A later cache operation will
      // report a useful error if the private storage cannot be opened.
    }
    try {
      const text = await fileIo.readText(this.indexPath)
      const parsed = JSON.parse(text) as JsonObject
      const rawItems = this.asRecord(parsed['items'])
      for (const key of Object.keys(rawItems)) {
        const raw = this.asRecord(rawItems[key])
        const path = this.stringValue(raw['path'])
        // Validate only on demand; startup must not stat every thumbnail and
        // every alias on the UI thread. Image failure handles external loss.
        if (!path.startsWith(this.directory + '/')) {
          continue
        }
        this.items.set(key, {
          path: path,
          lastAccessAt: this.numberValue(raw['lastAccessAt'], Date.now()),
          size: this.numberValue(raw['size'], 0)
        })
      }
      const migrated = this.promoteLegacyAliases()
      for (const key of Array.from(this.items.keys())) { this.indexPathKey(this.items.get(key)!.path, key) }
      this.itemCount = Array.from(this.items.keys()).length
      await this.trimIndex()
      if (migrated) {
        this.schedulePersist()
      }
    } catch (_) {
      this.items.clear()
      this.itemCount = 0
    }
  }

  private async trimIndex(): Promise<void> {
    if (this.itemCount <= ThumbnailCacheStore.MAX_INDEX_ITEMS) {
      return
    }
    const keys = Array.from(this.items.keys())
    keys.sort((left: string, right: string): number => {
      return this.items.get(left)!.lastAccessAt - this.items.get(right)!.lastAccessAt
    })
    // Leave headroom so steady browsing does not sort 40,000 aliases for
    // every newly generated thumbnail once the index reaches capacity.
    const removeCount = Math.max(128, keys.length - ThumbnailCacheStore.MAX_INDEX_ITEMS)
    const removedPaths: Record<string, boolean> = {}
    const removedKeys = keys.slice(0, removeCount)
    for (const key of removedKeys) {
      removedPaths[this.items.get(key)!.path] = true
    }
    this.removeKeys(removedKeys)
    const retainedPaths: Record<string, boolean> = {}
    for (const key of Array.from(this.items.keys())) {
      retainedPaths[this.items.get(key)!.path] = true
    }
    for (const path of Object.keys(removedPaths)) {
      if (retainedPaths[path] !== true) {
        await CacheManager.remove(path)
      }
    }
  }

  private removeKeys(keys: string[]): void {
    for (const key of keys) {
      const item = this.items.get(key)
      if (item === undefined) { continue }
      const aliases = this.keysByPath.get(item.path)
      aliases?.delete(key)
      if (aliases?.size === 0) { this.keysByPath.delete(item.path) }
      this.items.delete(key)
      this.itemCount -= 1
    }
  }

  private indexPathKey(path: string, key: string): void {
    let keys = this.keysByPath.get(path)
    if (keys === undefined) { keys = new Set(); this.keysByPath.set(path, keys) }
    keys.add(key)
  }

  private promoteLegacyAliases(): boolean {
    let changed = false
    for (const key of Array.from(this.items.keys())) {
      const identityKey = this.identityAliasForLegacyKey(key)
      if (identityKey.length > 0 && this.items.get(identityKey) === undefined) {
        this.items.set(identityKey, this.items.get(key)!)
        changed = true
      }
    }
    return changed
  }

  private identityAliasForLegacyKey(cacheKey: string): string {
    const match = /^thumbnail-v3:([^:]+):([^:]+):(.+):([0-9]+):([0-9]+):(.+)$/.exec(cacheKey)
    if (match === null || match.length < 7) {
      return ''
    }
    return 'thumbnail-v4:' + match[1] + ':' + match[2] + ':' + match[3] + ':' +
      match[4] + ':' + match[5]
  }

  private schedulePersist(): void {
    this.persistDirty = true
    if (this.persistTimer > 0) {
      return
    }
    this.persistTimer = setTimeout((): void => {
      this.persistTimer = 0
      if (!this.persistDirty) {
        return
      }
      this.persistDirty = false
      this.persist().catch((): void => {})
    }, 800)
  }

  private flushPersist(): Promise<void> {
    if (this.persistTimer > 0) {
      clearTimeout(this.persistTimer)
      this.persistTimer = 0
    }
    this.persistDirty = false
    if (this.accessPersistTimer > 0) {
      clearTimeout(this.accessPersistTimer)
      this.accessPersistTimer = 0
    }
    this.accessPersistDirty = false
    return this.persist()
  }

  private persist(): Promise<void> {
    const items: Record<string, ThumbnailCacheItem> = {}
    this.items.forEach((item: ThumbnailCacheItem, key: string): void => { items[key] = item })
    const document: ThumbnailCacheDocument = {
      version: 1,
      items: items
    }
    const content = JSON.stringify(document)
    const operation = this.writeQueue.then((): void => {
      if (this.indexPath.length === 0) {
        return
      }
      try {
        const file = fileIo.openSync(this.indexPath,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
        try {
          fileIo.writeSync(file.fd, content)
        } finally {
          fileIo.closeSync(file.fd)
        }
      } catch (_) {
        // The image file remains usable even when the tiny index write fails.
      }
    })
    this.writeQueue = operation.catch((): void => {})
    return operation
  }

  private asRecord(value: Object): Record<string, Object> {
    return value !== null && typeof value === 'object' ? value as Record<string, Object> : {}
  }

  private stringValue(value: Object | undefined): string {
    return typeof value === 'string' ? value : ''
  }

  private numberValue(value: Object | undefined, fallback: number): number {
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value
    }
    return fallback
  }
}

import { Context } from '@kit.AbilityKit'
import { fileIo } from '@kit.CoreFileKit'
import { CacheManager } from '../download/CacheManager'
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
  private items: Record<string, ThumbnailCacheItem> = {}
  private initPromise: Promise<void> | null = null
  private writeQueue: Promise<void> = Promise.resolve()
  private persistTimer: number = 0
  private persistDirty: boolean = false
  private accessPersistTimer: number = 0
  private accessPersistDirty: boolean = false
  private itemCount: number = 0

  async initialize(context: Context): Promise<void> {
    if (this.initPromise === null) {
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
    const indexed = this.items[cacheKey]
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
    const indexed = this.items[cacheKey]
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
    const isNewKey = this.items[cacheKey] === undefined
    this.items[cacheKey] = {
      path: path,
      lastAccessAt: Date.now(),
      size: size
    }
    if (isNewKey) {
      this.itemCount += 1
    }
    this.trimIndex()
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
    this.items = {}
    this.itemCount = 0
    await this.flushPersist()
  }

  private async enforceLimitNow(maxBytes: number): Promise<void> {
    if (maxBytes <= 0) {
      return
    }
    const staleKeys: string[] = []
    const indexedAccess: Record<string, number> = {}
    for (const key of Object.keys(this.items)) {
      const item = this.items[key]
      if (item === undefined || !CacheManager.exists(item.path)) {
        staleKeys.push(key)
        continue
      }
      const previous = indexedAccess[item.path]
      indexedAccess[item.path] = previous === undefined
        ? item.lastAccessAt : Math.max(previous, item.lastAccessAt)
    }
    if (staleKeys.length > 0) {
      this.removeKeys(staleKeys)
    }

    const files = this.listPhysicalFiles()
    let total = 0
    for (const file of files) {
      total += file.size
      const indexed = indexedAccess[file.path]
      file.lastAccessAt = indexed === undefined ? file.modifiedTime : indexed
    }
    files.sort((left: ThumbnailPhysicalFile, right: ThumbnailPhysicalFile): number => {
      return left.lastAccessAt - right.lastAccessAt
    })
    for (const file of files) {
      if (total <= maxBytes) {
        break
      }
      try {
        fileIo.unlinkSync(file.path)
        total = Math.max(0, total - file.size)
        this.removeKeysForPath(file.path)
      } catch (_) {
        // A single reclaimed or concurrently removed thumbnail must not stop
        // the remaining LRU candidates from being considered.
      }
    }
  }

  private listPhysicalFiles(): ThumbnailPhysicalFile[] {
    const result: ThumbnailPhysicalFile[] = []
    let names: string[] = []
    try {
      names = fileIo.listFileSync(this.directory)
    } catch (_) {
      return result
    }
    for (const name of names) {
      const path = this.directory + '/' + name
      try {
        const stat = fileIo.statSync(path)
        if (stat.isFile()) {
          result.push({
            path: path,
            size: stat.size,
            modifiedTime: stat.mtime * 1000,
            lastAccessAt: stat.mtime * 1000
          })
        }
      } catch (_) {
        // The file may disappear between listFileSync and statSync.
      }
    }
    return result
  }

  private removeKeysForPath(path: string): void {
    const keys: string[] = []
    for (const key of Object.keys(this.items)) {
      if (this.items[key].path === path) {
        keys.push(key)
      }
    }
    if (keys.length > 0) {
      this.removeKeys(keys)
    }
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
      const text = fileIo.readTextSync(this.indexPath)
      const parsed = JSON.parse(text) as JsonObject
      const rawItems = this.asRecord(parsed['items'])
      for (const key of Object.keys(rawItems)) {
        const raw = this.asRecord(rawItems[key])
        const path = this.stringValue(raw['path'])
        if (!path.startsWith(this.directory + '/') || !CacheManager.exists(path)) {
          continue
        }
        this.items[key] = {
          path: path,
          lastAccessAt: this.numberValue(raw['lastAccessAt'], Date.now()),
          size: this.numberValue(raw['size'], 0)
        }
      }
      const migrated = this.promoteLegacyAliases()
      this.itemCount = Object.keys(this.items).length
      this.trimIndex()
      if (migrated) {
        this.schedulePersist()
      }
    } catch (_) {
      this.items = {}
      this.itemCount = 0
    }
  }

  private trimIndex(): void {
    if (this.itemCount <= ThumbnailCacheStore.MAX_INDEX_ITEMS) {
      return
    }
    const keys = Object.keys(this.items)
    keys.sort((left: string, right: string): number => {
      return this.items[left].lastAccessAt - this.items[right].lastAccessAt
    })
    const removeCount = Math.max(0, keys.length - ThumbnailCacheStore.MAX_INDEX_ITEMS)
    const removedPaths: Record<string, boolean> = {}
    const removedKeys = keys.slice(0, removeCount)
    for (const key of removedKeys) {
      removedPaths[this.items[key].path] = true
    }
    this.removeKeys(removedKeys)
    const retainedPaths: Record<string, boolean> = {}
    for (const key of Object.keys(this.items)) {
      retainedPaths[this.items[key].path] = true
    }
    for (const path of Object.keys(removedPaths)) {
      if (retainedPaths[path] !== true) {
        try { fileIo.unlinkSync(path) } catch (_) {}
      }
    }
  }

  private removeKeys(keys: string[]): void {
    const removed: Record<string, boolean> = {}
    for (const key of keys) {
      removed[key] = true
    }
    const next: Record<string, ThumbnailCacheItem> = {}
    for (const key of Object.keys(this.items)) {
      if (removed[key] !== true) {
        next[key] = this.items[key]
      }
    }
    this.items = next
    this.itemCount = Object.keys(next).length
  }

  private promoteLegacyAliases(): boolean {
    let changed = false
    for (const key of Object.keys(this.items)) {
      const identityKey = this.identityAliasForLegacyKey(key)
      if (identityKey.length > 0 && this.items[identityKey] === undefined) {
        this.items[identityKey] = this.items[key]
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
    const document: ThumbnailCacheDocument = {
      version: 1,
      items: this.items
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

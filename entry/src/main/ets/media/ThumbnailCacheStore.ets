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

/**
 * Persistent index and storage boundary for list thumbnails.
 *
 * Thumbnails are deliberately kept outside cacheDir. cacheDir is disposable
 * and HarmonyOS may reclaim it without asking the application. This store
 * uses the private files directory and keeps its own bounded LRU directory.
 */
export class ThumbnailCacheStore {
  static readonly DEFAULT_LIMIT_BYTES: number = 256 * 1024 * 1024
  private static readonly DIRECTORY_NAME: string = 'ugreen-thumbnail-cache'
  private static readonly INDEX_FILE_NAME: string = 'ugreen-thumbnail-index.json'
  private static readonly MAX_INDEX_ITEMS: number = 512

  private directory: string = ''
  private indexPath: string = ''
  private items: Record<string, ThumbnailCacheItem> = {}
  private initPromise: Promise<void> | null = null
  private writeQueue: Promise<void> = Promise.resolve()

  async initialize(context: Context): Promise<void> {
    if (this.initPromise === null) {
      this.initPromise = this.open(context)
    }
    await this.initPromise
  }

  directoryPath(): string {
    return this.directory
  }

  async find(cacheKey: string, fileName: string): Promise<string> {
    if (cacheKey.length === 0 || fileName.length === 0 || this.directory.length === 0) {
      return ''
    }
    const indexed = this.items[cacheKey]
    if (indexed !== undefined && CacheManager.exists(indexed.path)) {
      this.touch(indexed.path)
      indexed.lastAccessAt = Date.now()
      await this.persist()
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
    this.items[cacheKey] = {
      path: path,
      lastAccessAt: Date.now(),
      size: size
    }
    this.trimIndex()
    await this.persist()
  }

  async enforceLimit(maxBytes: number): Promise<void> {
    if (this.directory.length === 0) {
      return
    }
    await CacheManager.enforceLimit(this.directory, maxBytes)
    const staleKeys: string[] = []
    for (const key of Object.keys(this.items)) {
      const item = this.items[key]
      if (item === undefined || !CacheManager.exists(item.path)) {
        staleKeys.push(key)
      }
    }
    for (const key of staleKeys) {
      this.removeKeys([key])
    }
    await this.persist()
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
    await this.persist()
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
        if (path.length === 0 || !CacheManager.exists(path)) {
          continue
        }
        this.items[key] = {
          path: path,
          lastAccessAt: this.numberValue(raw['lastAccessAt'], Date.now()),
          size: this.numberValue(raw['size'], 0)
        }
      }
      this.trimIndex()
    } catch (_) {
      this.items = {}
    }
  }

  private touch(path: string): void {
    try {
      // CacheManager's LRU is based on file mtime. Keep it aligned with the
      // persistent index's logical access time.
      fileIo.utimes(path, Date.now())
    } catch (_) {
      // A best-effort touch must never block displaying a cached thumbnail.
    }
  }

  private trimIndex(): void {
    const keys = Object.keys(this.items)
    if (keys.length <= ThumbnailCacheStore.MAX_INDEX_ITEMS) {
      return
    }
    keys.sort((left: string, right: string): number => {
      return this.items[left].lastAccessAt - this.items[right].lastAccessAt
    })
    while (keys.length > ThumbnailCacheStore.MAX_INDEX_ITEMS) {
      const oldest = keys.shift()
      if (oldest === undefined) {
        break
      }
      this.removeKeys([oldest])
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

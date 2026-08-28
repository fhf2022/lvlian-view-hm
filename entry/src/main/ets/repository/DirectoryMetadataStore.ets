import { Context } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'
import { FileEntry } from '../model/FileEntry'
import { JsonObject } from '../core/network/HttpTypes'

export interface DirectoryMetadataSnapshot {
  entries: FileEntry[]
  fetchedAt: number
  totalCount: number
}

export interface DirectoryMetadataPage {
  pageIndex: number
  entries: FileEntry[]
  fetchedAt: number
  totalCount: number
  hasMore: boolean
}

interface CacheIndexRow {
  scope: string
  rootType: number
  path: string
  totalBytes: number
}

/**
 * Persistent metadata cache for directory snapshots.
 *
 * The database stores only remote metadata. File contents and thumbnails stay
 * in the app cache directory and are managed by CacheManager.
 */
export class DirectoryMetadataStore {
  private static readonly DATABASE_NAME: string = 'ugreen_directory_cache'
  private static readonly DATABASE_VERSION: number = 2
  private static readonly MAX_TOTAL_CACHE_BYTES: number = 64 * 1024 * 1024
  private static readonly MAX_PAGE_BYTES: number = 512 * 1024
  private static readonly PAGE_SIZE: number = 200

  private store: relationalStore.RdbStore | null = null
  private initPromise: Promise<void> | null = null
  private writeQueue: Promise<void> = Promise.resolve()
  private snapshotSequence: number = 0

  async initialize(context: Context): Promise<void> {
    if (this.initPromise === null) {
      this.initPromise = this.open(context)
    }
    await this.initPromise
  }

  async read(scope: string, path: string, rootType: number): Promise<DirectoryMetadataSnapshot | null> {
    const store = await this.readyStore()
    if (store === null || scope.length === 0) {
      return null
    }

    let resultSet: relationalStore.ResultSet | null = null
    try {
      resultSet = await store.querySql(
        'SELECT snapshot_id, fetched_at, total_count, page_count ' +
          'FROM directory_cache_index WHERE scope = ? AND root_type = ? AND path = ? LIMIT 1',
        [scope, rootType, path]
      )
      if (!resultSet.goToFirstRow()) {
        return null
      }

      const snapshotId = resultSet.getLong(0)
      const fetchedAt = resultSet.getLong(1)
      const totalCount = resultSet.getLong(2)
      const pageCount = resultSet.getLong(3)
      if (pageCount <= 0) {
        return null
      }

      resultSet.close()
      resultSet = null
      resultSet = await store.querySql(
        'SELECT page_index, entries_json FROM directory_cache_pages ' +
          'WHERE scope = ? AND root_type = ? AND path = ? AND snapshot_id = ? ' +
          'ORDER BY page_index ASC',
        [scope, rootType, path, snapshotId]
      )

      const entries: FileEntry[] = []
      let expectedPageIndex = 0
      if (resultSet.goToFirstRow()) {
        do {
          if (resultSet.getLong(0) !== expectedPageIndex) {
            return null
          }
          const pageEntries = this.decodeEntries(resultSet.getString(1))
          if (pageEntries === null) {
            return null
          }
          for (const entry of pageEntries) {
            entries.push(entry)
          }
          expectedPageIndex += 1
        } while (resultSet.goToNextRow())
      }
      if (expectedPageIndex !== pageCount) {
        return null
      }

      // Access time is updated asynchronously so opening a cached directory
      // does not wait behind unrelated cache writes.
      this.touch(scope, rootType, path, snapshotId)
      return {
        entries: entries,
        fetchedAt: fetchedAt,
        totalCount: totalCount >= 0 ? totalCount : entries.length
      }
    } catch (_) {
      return null
    } finally {
      if (resultSet !== null) {
        resultSet.close()
      }
    }
  }

  async readPage(scope: string, path: string, rootType: number,
    pageIndex: number): Promise<DirectoryMetadataPage | null> {
    const store = await this.readyStore()
    if (store === null || scope.length === 0 || pageIndex < 1) {
      return null
    }

    let resultSet: relationalStore.ResultSet | null = null
    try {
      resultSet = await store.querySql(
        'SELECT snapshot_id, fetched_at, total_count FROM directory_cache_index ' +
          'WHERE scope = ? AND root_type = ? AND path = ? LIMIT 1',
        [scope, rootType, path]
      )
      if (!resultSet.goToFirstRow()) {
        return null
      }
      const snapshotId = resultSet.getLong(0)
      const fetchedAt = resultSet.getLong(1)
      const totalCount = resultSet.getLong(2)
      resultSet.close()
      resultSet = null
      resultSet = await store.querySql(
        'SELECT entries_json FROM directory_cache_pages WHERE scope = ? AND ' +
          'root_type = ? AND path = ? AND snapshot_id = ? AND page_index = ? LIMIT 1',
        [scope, rootType, path, snapshotId, pageIndex - 1]
      )
      if (!resultSet.goToFirstRow()) {
        return null
      }
      const entries = this.decodeEntries(resultSet.getString(0))
      if (entries === null) {
        return null
      }
      this.touch(scope, rootType, path, snapshotId)
      return {
        pageIndex: pageIndex,
        entries: entries,
        fetchedAt: fetchedAt,
        totalCount: totalCount >= 0 ? totalCount : entries.length,
        hasMore: totalCount >= 0
          ? pageIndex * DirectoryMetadataStore.PAGE_SIZE < totalCount
          : entries.length >= DirectoryMetadataStore.PAGE_SIZE
      }
    } catch (_) {
      return null
    } finally {
      if (resultSet !== null) {
        resultSet.close()
      }
    }
  }

  async saveSnapshot(scope: string, path: string, rootType: number,
    pages: FileEntry[][], totalCount: number): Promise<void> {
    if (scope.length === 0 || pages.length === 0) {
      return
    }

    const serializedPages: string[] = []
    let totalBytes = 0
    try {
      for (const entries of pages) {
        const entriesJson = JSON.stringify(entries)
        const pageBytes = entriesJson.length * 2
        if (entriesJson.length === 0 || pageBytes > DirectoryMetadataStore.MAX_PAGE_BYTES) {
          return
        }
        serializedPages.push(entriesJson)
        totalBytes += pageBytes
      }
    } catch (_) {
      return
    }

    const normalizedTotalCount = totalCount >= 0 ? totalCount : pages.reduce(
      (count: number, entries: FileEntry[]): number => count + entries.length, 0)
    const operation = this.writeQueue.then(async (): Promise<void> => {
      const store = await this.readyStore()
      if (store === null) {
        return
      }

      const now = Date.now()
      const snapshotId = this.nextSnapshotId()
      for (let index = 0; index < serializedPages.length; index++) {
        await store.executeSql(
          'INSERT OR REPLACE INTO directory_cache_pages ' +
            '(scope, root_type, path, snapshot_id, page_index, entries_json) ' +
            'VALUES (?, ?, ?, ?, ?, ?)',
          [scope, rootType, path, snapshotId, index, serializedPages[index]]
        )
      }
      await store.executeSql(
        'INSERT OR REPLACE INTO directory_cache_index ' +
          '(scope, root_type, path, snapshot_id, fetched_at, last_access_at, ' +
          'total_count, page_count, total_bytes) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [scope, rootType, path, snapshotId, now, now, normalizedTotalCount,
          serializedPages.length, totalBytes]
      )
      await store.executeSql(
        'DELETE FROM directory_cache_pages WHERE scope = ? AND root_type = ? AND path = ? ' +
          'AND snapshot_id <> ?',
        [scope, rootType, path, snapshotId]
      )
      await this.cleanupOrphanPages(store)
      await this.trim(store)
    })
    this.writeQueue = operation.catch((): void => {})
    await operation.catch((): void => {})
  }

  async savePage(scope: string, path: string, rootType: number, pageIndex: number,
    entries: FileEntry[], totalCount: number): Promise<void> {
    if (scope.length === 0 || pageIndex < 1 || entries.length === 0) {
      return
    }
    let entriesJson = ''
    try {
      entriesJson = JSON.stringify(entries)
    } catch (_) {
      return
    }
    if (entriesJson.length === 0 || entriesJson.length * 2 > DirectoryMetadataStore.MAX_PAGE_BYTES) {
      return
    }

    const operation = this.writeQueue.then(async (): Promise<void> => {
      const store = await this.readyStore()
      if (store === null) {
        return
      }
      const now = Date.now()
      let snapshotId = this.nextSnapshotId()
      let fetchedAt = now
      let existing: relationalStore.ResultSet | null = null
      try {
        existing = await store.querySql(
          'SELECT snapshot_id, fetched_at FROM directory_cache_index ' +
            'WHERE scope = ? AND root_type = ? AND path = ? LIMIT 1',
          [scope, rootType, path]
        )
        if (existing.goToFirstRow()) {
          snapshotId = existing.getLong(0)
          fetchedAt = existing.getLong(1)
        }
      } finally {
        if (existing !== null) {
          existing.close()
        }
      }

      await store.executeSql(
        'INSERT OR REPLACE INTO directory_cache_pages ' +
          '(scope, root_type, path, snapshot_id, page_index, entries_json) ' +
          'VALUES (?, ?, ?, ?, ?, ?)',
        [scope, rootType, path, snapshotId, pageIndex - 1, entriesJson]
      )
      let stats: relationalStore.ResultSet | null = null
      let pageCount = pageIndex
      let totalBytes = entriesJson.length * 2
      try {
        stats = await store.querySql(
          'SELECT COUNT(*), COALESCE(SUM(LENGTH(entries_json) * 2), 0) ' +
            'FROM directory_cache_pages WHERE scope = ? AND root_type = ? AND path = ? ' +
            'AND snapshot_id = ?',
          [scope, rootType, path, snapshotId]
        )
        if (stats.goToFirstRow()) {
          pageCount = Math.max(pageCount, stats.getLong(0))
          totalBytes = stats.getLong(1)
        }
      } finally {
        if (stats !== null) {
          stats.close()
        }
      }
      await store.executeSql(
        'INSERT OR REPLACE INTO directory_cache_index ' +
          '(scope, root_type, path, snapshot_id, fetched_at, last_access_at, ' +
          'total_count, page_count, total_bytes) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [scope, rootType, path, snapshotId, fetchedAt, now,
          totalCount >= 0 ? totalCount : pageIndex * DirectoryMetadataStore.PAGE_SIZE,
          pageCount, totalBytes]
      )
      await this.cleanupOrphanPages(store)
      await this.trim(store)
    })
    this.writeQueue = operation.catch((): void => {})
    await operation.catch((): void => {})
  }

  async clear(scope: string = ''): Promise<void> {
    const operation = this.writeQueue.then(async (): Promise<void> => {
      const store = await this.readyStore()
      if (store === null) {
        return
      }
      if (scope.length === 0) {
        await store.executeSql('DELETE FROM directory_cache_pages')
        await store.executeSql('DELETE FROM directory_cache_index')
      } else {
        await store.executeSql('DELETE FROM directory_cache_pages WHERE scope = ?', [scope])
        await store.executeSql('DELETE FROM directory_cache_index WHERE scope = ?', [scope])
      }
      this.snapshotSequence = 0
    })
    this.writeQueue = operation.catch((): void => {})
    await operation.catch((): void => {})
  }

  private async open(context: Context): Promise<void> {
    try {
      const config: relationalStore.StoreConfig = {
        name: DirectoryMetadataStore.DATABASE_NAME,
        securityLevel: relationalStore.SecurityLevel.S2,
        encrypt: true,
        allowRebuild: true
      }
      this.store = await relationalStore.getRdbStore(context, config)
      if (this.store.version < DirectoryMetadataStore.DATABASE_VERSION) {
        // The previous version stored one large JSON row per directory. The
        // cache is disposable, so migrate by rebuilding only these cache tables.
        await this.store.executeSql('DROP TABLE IF EXISTS directory_cache')
        await this.store.executeSql('DROP TABLE IF EXISTS directory_cache_index')
        await this.store.executeSql('DROP TABLE IF EXISTS directory_cache_pages')
      }
      await this.store.executeSql(
        'CREATE TABLE IF NOT EXISTS directory_cache_index (' +
          'scope TEXT NOT NULL, ' +
          'root_type INTEGER NOT NULL, ' +
          'path TEXT NOT NULL, ' +
          'snapshot_id INTEGER NOT NULL, ' +
          'fetched_at INTEGER NOT NULL, ' +
          'last_access_at INTEGER NOT NULL, ' +
          'total_count INTEGER NOT NULL, ' +
          'page_count INTEGER NOT NULL, ' +
          'total_bytes INTEGER NOT NULL, ' +
          'PRIMARY KEY (scope, root_type, path)' +
        ')'
      )
      await this.store.executeSql(
        'CREATE TABLE IF NOT EXISTS directory_cache_pages (' +
          'scope TEXT NOT NULL, ' +
          'root_type INTEGER NOT NULL, ' +
          'path TEXT NOT NULL, ' +
          'snapshot_id INTEGER NOT NULL, ' +
          'page_index INTEGER NOT NULL, ' +
          'entries_json TEXT NOT NULL, ' +
          'PRIMARY KEY (scope, root_type, path, snapshot_id, page_index)' +
        ')'
      )
      await this.store.executeSql(
        'CREATE INDEX IF NOT EXISTS idx_directory_cache_lru ' +
          'ON directory_cache_index (last_access_at)'
      )
      this.store.version = DirectoryMetadataStore.DATABASE_VERSION
      await this.cleanupOrphanPages(this.store)
    } catch (_) {
      // Directory metadata is disposable. Network browsing remains available
      // when the local database cannot be opened or rebuilt.
      this.store = null
    }
  }

  private async readyStore(): Promise<relationalStore.RdbStore | null> {
    if (this.initPromise === null) {
      return null
    }
    await this.initPromise
    return this.store
  }

  private touch(scope: string, rootType: number, path: string, snapshotId: number): void {
    const operation = this.writeQueue.then(async (): Promise<void> => {
      const store = await this.readyStore()
      if (store === null) {
        return
      }
      await store.executeSql(
        'UPDATE directory_cache_index SET last_access_at = ? ' +
          'WHERE scope = ? AND root_type = ? AND path = ? AND snapshot_id = ?',
        [Date.now(), scope, rootType, path, snapshotId]
      )
    })
    this.writeQueue = operation.catch((): void => {})
  }

  private async trim(store: relationalStore.RdbStore): Promise<void> {
    let resultSet: relationalStore.ResultSet | null = null
    const rows: CacheIndexRow[] = []
    let totalBytes = 0
    try {
      resultSet = await store.querySql(
        'SELECT scope, root_type, path, total_bytes ' +
          'FROM directory_cache_index ORDER BY last_access_at ASC'
      )
      if (resultSet.goToFirstRow()) {
        do {
          const row: CacheIndexRow = {
            scope: resultSet.getString(0),
            rootType: resultSet.getLong(1),
            path: resultSet.getString(2),
            totalBytes: resultSet.getLong(3)
          }
          rows.push(row)
          totalBytes += row.totalBytes
        } while (resultSet.goToNextRow())
      }
    } catch (_) {
      return
    } finally {
      if (resultSet !== null) {
        resultSet.close()
      }
    }

    if (totalBytes <= DirectoryMetadataStore.MAX_TOTAL_CACHE_BYTES) {
      return
    }
    for (const row of rows) {
      if (totalBytes <= DirectoryMetadataStore.MAX_TOTAL_CACHE_BYTES) {
        break
      }
      try {
        await store.executeSql(
          'DELETE FROM directory_cache_pages WHERE scope = ? AND root_type = ? AND path = ?',
          [row.scope, row.rootType, row.path]
        )
        await store.executeSql(
          'DELETE FROM directory_cache_index WHERE scope = ? AND root_type = ? AND path = ?',
          [row.scope, row.rootType, row.path]
        )
        totalBytes -= row.totalBytes
      } catch (_) {
        // Cache cleanup is best effort and must not affect browsing.
      }
    }
  }

  private async cleanupOrphanPages(store: relationalStore.RdbStore): Promise<void> {
    try {
      await store.executeSql(
        'DELETE FROM directory_cache_pages WHERE snapshot_id NOT IN ' +
          '(SELECT snapshot_id FROM directory_cache_index)'
      )
    } catch (_) {
      // An orphan cleanup failure is harmless; the next save can retry it.
    }
  }

  private nextSnapshotId(): number {
    const now = Date.now()
    this.snapshotSequence = Math.max(this.snapshotSequence + 1, now)
    return this.snapshotSequence
  }

  private decodeEntries(json: string): FileEntry[] | null {
    try {
      const values = JSON.parse(json) as Object
      if (!(values instanceof Array)) {
        return null
      }
      const entries: FileEntry[] = []
      for (const value of values as Object[]) {
        const raw = value as JsonObject
        const entry = new FileEntry()
        entry.name = this.stringValue(raw['name'])
        entry.path = this.stringValue(raw['path'])
        entry.isDirectory = this.booleanValue(raw['isDirectory'])
        entry.size = this.numberValue(raw['size'])
        entry.modifiedTime = this.numberValue(raw['modifiedTime'])
        entry.createdTime = this.numberValue(raw['createdTime'])
        entry.childCount = this.numberValue(raw['childCount'], -1)
        entry.rootType = this.numberValue(raw['rootType'])
        entry.intranetShareId = this.numberValue(raw['intranetShareId'])
        entry.thumbnailUrl = this.stringValue(raw['thumbnailUrl'])
        entry.coverUrl = this.stringValue(raw['coverUrl'])
        entry.mimeType = this.stringValue(raw['mimeType'])
        entry.etag = this.stringValue(raw['etag'])
        entry.checksum = this.stringValue(raw['checksum'])
        entries.push(entry)
      }
      return entries
    } catch (_) {
      return null
    }
  }

  private stringValue(value: Object): string {
    return typeof value === 'string' ? value : ''
  }

  private booleanValue(value: Object): boolean {
    return typeof value === 'boolean' ? value : false
  }

  private numberValue(value: Object, fallback: number = 0): number {
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value
    }
    if (typeof value === 'string') {
      const parsed = Number(value)
      if (Number.isFinite(parsed)) {
        return parsed
      }
    }
    return fallback
  }
}

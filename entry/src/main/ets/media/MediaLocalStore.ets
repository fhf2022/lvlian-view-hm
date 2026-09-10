import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'

/**
 * The remote signature is intentionally small and serialisable. Path, size
 * and modification time are available from the current file-manager API;
 * ETag/checksum are optional validators exposed by newer gateways.
 */
export class RemoteFileSignature {
  scopeKey: string = ''
  path: string = ''
  size: number = 0
  modifiedTime: number = 0
  etag: string = ''
  checksum: string = ''

  constructor(scopeKey: string = '', path: string = '', size: number = 0,
    modifiedTime: number = 0, etag: string = '', checksum: string = '') {
    this.scopeKey = scopeKey
    this.path = path
    this.size = Math.max(0, size)
    this.modifiedTime = Math.max(0, modifiedTime)
    this.etag = etag
    this.checksum = checksum
  }

  key(): string {
    return 'video-v1:' + this.scopeKey + ':' + this.path + ':' + this.size.toString() + ':' +
      this.modifiedTime.toString() + ':' + this.etag + ':' + this.checksum
  }
}

export type MediaLocalStatus = 'partial' | 'cached' | 'downloaded' | 'failed'

export class MediaLocalRecord {
  sourceKey: string = ''
  scopeKey: string = ''
  remotePath: string = ''
  name: string = ''
  size: number = 0
  modifiedTime: number = 0
  etag: string = ''
  checksum: string = ''
  cachePath: string = ''
  partPath: string = ''
  durablePath: string = ''
  // Inclusive/exclusive byte ranges encoded as "start-end". The list is
  // normalised before persistence and represents unique bytes, not file size.
  ranges: string[] = []
  receivedBytes: number = 0
  totalBytes: number = 0
  status: MediaLocalStatus = 'partial'
  userDownload: boolean = false
  relativePath: string = ''
  playbackPositionMs: number = 0
  updatedAt: number = 0
}

export type MediaLocalListener = (records: MediaLocalRecord[]) => void

/**
 * Small account-scoped index for cache and Download routing. The files remain
 * in the existing cacheDir or public Download/UGREENlink directory; only the
 * mapping is persisted here. This lets a completed file survive removal of a
 * visible download task.
 */
export class MediaLocalStore {
  private static readonly PREFERENCES_NAME: string = 'ugreen-media-local'
  private static readonly RECORDS_KEY: string = 'records_v1'
  private preferencesStore: preferences.Preferences | null = null
  private records: Record<string, MediaLocalRecord> = {}
  private listeners: MediaLocalListener[] = []
  private persistTimer: number = 0

  async initialize(context: Context, scopeKey: string): Promise<void> {
    const scopedName = MediaLocalStore.PREFERENCES_NAME + '-' + this.safeScope(scopeKey)
    try {
      this.preferencesStore = await preferences.getPreferences(context, scopedName)
      const stored = await this.preferencesStore.get(MediaLocalStore.RECORDS_KEY, '{}')
      if (typeof stored === 'string') {
        this.load(stored)
      }
    } catch (error) {
      console.warn('[UgreenMedia] local index unavailable: ' + JSON.stringify(error))
    }
  }

  onChange(listener: MediaLocalListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  find(sourceKey: string): MediaLocalRecord | null {
    const value = this.records[sourceKey]
    return value === undefined ? null : this.copy(value)
  }

  snapshot(): MediaLocalRecord[] {
    const result: MediaLocalRecord[] = []
    for (const key of Object.keys(this.records)) {
      result.push(this.copy(this.records[key]))
    }
    return result
  }

  put(record: MediaLocalRecord): void {
    if (record.sourceKey.length === 0) {
      return
    }
    record.updatedAt = Date.now()
    this.records[record.sourceKey] = this.copy(record)
    this.schedulePersist()
    this.notify()
  }

  remove(sourceKey: string): void {
    if (sourceKey.length === 0 || this.records[sourceKey] === undefined) {
      return
    }
    const remaining: Record<string, MediaLocalRecord> = {}
    for (const key of Object.keys(this.records)) {
      if (key !== sourceKey) {
        remaining[key] = this.records[key]
      }
    }
    this.records = remaining
    this.schedulePersist()
    this.notify()
  }

  async flush(): Promise<void> {
    if (this.persistTimer > 0) {
      clearTimeout(this.persistTimer)
      this.persistTimer = 0
    }
    await this.persist()
  }

  private load(json: string): void {
    try {
      const parsed = JSON.parse(json) as Record<string, Object>
      for (const key of Object.keys(parsed)) {
        const value = parsed[key] as Record<string, Object>
        const record = new MediaLocalRecord()
        record.sourceKey = this.stringValue(value['sourceKey'])
        record.scopeKey = this.stringValue(value['scopeKey'])
        record.remotePath = this.stringValue(value['remotePath'])
        record.name = this.stringValue(value['name'])
        record.size = this.numberValue(value['size'])
        record.modifiedTime = this.numberValue(value['modifiedTime'])
        record.etag = this.stringValue(value['etag'])
        record.checksum = this.stringValue(value['checksum'])
        record.cachePath = this.stringValue(value['cachePath'])
        record.partPath = this.stringValue(value['partPath'])
        record.durablePath = this.stringValue(value['durablePath'])
        record.userDownload = typeof value['userDownload'] === 'boolean' ? value['userDownload'] === true :
          record.durablePath.length > 0 || record.partPath.length > 0
        record.relativePath = this.stringValue(value['relativePath'])
        const ranges = value['ranges']
        record.ranges = ranges instanceof Array
          ? ranges.filter((item: Object): boolean => typeof item === 'string') as string[] : []
        record.receivedBytes = this.numberValue(value['receivedBytes'])
        record.totalBytes = this.numberValue(value['totalBytes'])
        record.status = this.statusValue(value['status'])
        record.playbackPositionMs = this.numberValue(value['playbackPositionMs'])
        record.updatedAt = this.numberValue(value['updatedAt'])
        if (record.sourceKey.length > 0) {
          this.records[key] = record
        }
      }
    } catch (error) {
      console.warn('[UgreenMedia] local index parse failed: ' + JSON.stringify(error))
    }
  }

  private schedulePersist(): void {
    if (this.persistTimer > 0) {
      return
    }
    this.persistTimer = setTimeout((): void => {
      this.persistTimer = 0
      this.persist().catch((error: Object): void => {
        console.warn('[UgreenMedia] local index persist failed: ' + JSON.stringify(error))
      })
    }, 300)
  }

  private async persist(): Promise<void> {
    if (this.preferencesStore === null) {
      throw new Error('本地存储未就绪，无法保存下载记录')
    }
    await this.preferencesStore.put(MediaLocalStore.RECORDS_KEY, JSON.stringify(this.records))
    await this.preferencesStore.flush()
  }

  private notify(): void {
    const snapshot = this.snapshot()
    for (const listener of this.listeners.slice()) {
      try {
        listener(snapshot)
      } catch (error) {
        console.warn('[UgreenMedia] local index listener failed: ' + JSON.stringify(error))
      }
    }
  }

  private copy(source: MediaLocalRecord): MediaLocalRecord {
    const result = new MediaLocalRecord()
    result.sourceKey = source.sourceKey
    result.scopeKey = source.scopeKey
    result.remotePath = source.remotePath
    result.name = source.name
    result.size = source.size
    result.modifiedTime = source.modifiedTime
    result.etag = source.etag
    result.checksum = source.checksum
    result.cachePath = source.cachePath
    result.partPath = source.partPath
    result.durablePath = source.durablePath
    result.ranges = source.ranges.slice()
    result.receivedBytes = source.receivedBytes
    result.totalBytes = source.totalBytes
    result.status = source.status
    result.userDownload = source.userDownload
    result.relativePath = source.relativePath
    result.playbackPositionMs = source.playbackPositionMs
    result.updatedAt = source.updatedAt
    return result
  }

  private stringValue(value: Object | undefined): string {
    return typeof value === 'string' ? value : ''
  }

  private numberValue(value: Object | undefined): number {
    return typeof value === 'number' && Number.isFinite(value) ? Math.max(0, value) : 0
  }

  private statusValue(value: Object | undefined): MediaLocalStatus {
    if (value === 'cached' || value === 'downloaded' || value === 'failed') {
      if (value === 'cached') {
        return 'cached'
      }
      if (value === 'downloaded') {
        return 'downloaded'
      }
      return 'failed'
    }
    return 'partial'
  }

  private safeScope(value: string): string {
    const clean = value.length > 0 ? value : 'anonymous'
    return clean.replace(/[^A-Za-z0-9_-]/g, '_').substring(0, 80)
  }
}

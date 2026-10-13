export type AlbumUploadState = 'building' | 'queued' | 'checking' | 'running' | 'paused' |
  'waiting_wifi' | 'waiting_server' | 'waiting_foreground' | 'completed' | 'failed'
export type AlbumItemState = 'pending' | 'active' | 'uploaded' | 'skipped' | 'failed'

export class LocalImageAlbum {
  uri: string = ''
  name: string = ''
  path: string = ''
  type: number = 0
  subtype: number = 0
  localCount: number = 0
  movingCount: number = 0
}

export class AlbumUploadItem {
  id: string = ''
  batchId: string = ''
  uri: string = ''
  name: string = ''
  targetName: string = ''
  size: number = 0
  modified: number = 0
  state: AlbumItemState = 'pending'
  error: string = ''
  prepared: boolean = false
}

export class AlbumUploadJob {
  id: string = ''
  scope: string = ''
  albumUri: string = ''
  albumName: string = ''
  destination: string = ''
  rootType: number = 0
  state: AlbumUploadState = 'building'
  total: number = 0
  uploaded: number = 0
  skipped: number = 0
  failed: number = 0
  bytes: number = 0
  createdAt: number = 0
  // Kept for the existing SQLite schema; background upload no longer holds the screen awake.
  keepScreenOn: boolean = false
  error: string = ''
  currentName: string = ''
  currentBytes: number = 0
  currentSize: number = 0
  completedBytes: number = 0
}

export interface AlbumUploadSource {
  snapshot(album: LocalImageAlbum, consume: (items: AlbumUploadItem[]) => Promise<void>,
    check: () => void): Promise<number>
  validate(item: AlbumUploadItem): Promise<void>
}

/** Stable names make retries idempotent, while preserving same-name different-size files. */
export class AlbumUploadPolicy {
  static validName(name: string): boolean {
    return name.length > 0 && name !== '.' && name !== '..' && !/[\r\n\x00\/\\]/.test(name)
  }
  static versionKey(item: AlbumUploadItem): string {
    return item.uri + ':' + item.size.toString() + ':' + item.modified.toString()
  }
  static alternateName(item: AlbumUploadItem, attempt: number): string {
    const key = AlbumUploadPolicy.versionKey(item)
    let first = 2166136261
    let second = 5381
    for (let index = 0; index < key.length; index++) {
      first = Math.imul(first ^ key.charCodeAt(index), 16777619) >>> 0
      second = (Math.imul(second, 33) ^ key.charCodeAt(index)) >>> 0
    }
    const dot = item.name.lastIndexOf('.')
    const extension = dot > 0 ? item.name.substring(dot) : ''
    const stem = dot > 0 ? item.name.substring(0, dot) : item.name
    const suffix = '（相册-' + first.toString(16) + second.toString(16) +
      (attempt > 0 ? '-' + attempt.toString() : '') + '）'
    // Leave room for multibyte names and NAS filesystem byte limits.
    return AlbumUploadPolicy.prefix(stem, 50) + suffix + AlbumUploadPolicy.prefix(extension, 16)
  }
  private static prefix(value: string, length: number): string {
    let end = Math.min(value.length, length)
    if (end < value.length && end > 0 && value.charCodeAt(end - 1) >= 0xD800 &&
      value.charCodeAt(end - 1) <= 0xDBFF) { end-- }
    return value.substring(0, end)
  }
  static canRun(state: AlbumUploadState): boolean {
    return state === 'queued' || state === 'checking' || state === 'running' ||
      state === 'waiting_wifi' || state === 'waiting_server' || state === 'waiting_foreground'
  }
}

// R2 原型：让 FileEntry 可被 @ObjectLink 观察。
// 网格 cell 抽成子组件后，`previewRevision` 的就地自增只通知绑定了该实例的
// cell 重算，不再经过根组件 Index 的整树 build。
@Observed
export class FileEntry {
  name: string = ''
  path: string = ''
  isDirectory: boolean = false
  size: number = 0
  modifiedTime: number = 0
  // UGOS mediaPlayer URLs also carry the creation time.  Older list
  // responses may omit it, so zero remains a valid fallback.
  createdTime: number = 0
  childCount: number = -1
  rootType: number = 0
  // Shared-folder media sources use this value when the gateway exposes it.
  intranetShareId: number = 0
  thumbnailUrl: string = ''
  coverUrl: string = ''
  mimeType: string = ''
  // Optional server supplied validators. Older UGOS endpoints do not return
  // these fields, so callers must still be able to fall back to size/mtime.
  etag: string = ''
  checksum: string = ''
  // Recycle-bin bookkeeping. UGOS keeps deleted items in a hidden
  // `<folder>/#recycle` repository that mirrors the original tree, so an item
  // found there still carries its own name and size; only the deletion time
  // cannot be derived from the path and has to come from the server.
  // Both stay at their defaults for ordinary directory entries.
  deletedTime: number = 0
  recycleInPath: boolean = false
  // Absolute path of the share whose `#recycle` folder produced this entry.
  // Restoring needs it to strip the repository segment and rebuild the
  // original location; it is empty for entries that are not recycled.
  recycleSharePath: string = ''
  // 缩略图/单项数据更新版本号：使 onDataChange(index) 时数据项具备可观察变化
  previewRevision: number = 0

  /** Refresh descriptors without disconnecting an already mounted @ObjectLink. */
  updateFrom(entry: FileEntry): void {
    this.name = entry.name
    this.path = entry.path
    this.isDirectory = entry.isDirectory
    this.size = entry.size
    this.modifiedTime = entry.modifiedTime
    this.createdTime = entry.createdTime
    this.childCount = entry.childCount
    this.rootType = entry.rootType
    this.intranetShareId = entry.intranetShareId
    this.thumbnailUrl = entry.thumbnailUrl
    this.coverUrl = entry.coverUrl
    this.mimeType = entry.mimeType
    this.etag = entry.etag
    this.checksum = entry.checksum
    this.deletedTime = entry.deletedTime
    this.recycleInPath = entry.recycleInPath
    this.recycleSharePath = entry.recycleSharePath
    // previewRevision belongs to the mounted instance, not the NAS response.
  }

  clone(): FileEntry {
    const entry = new FileEntry()
    entry.name = this.name
    entry.path = this.path
    entry.isDirectory = this.isDirectory
    entry.size = this.size
    entry.modifiedTime = this.modifiedTime
    entry.createdTime = this.createdTime
    entry.childCount = this.childCount
    entry.rootType = this.rootType
    entry.intranetShareId = this.intranetShareId
    entry.thumbnailUrl = this.thumbnailUrl
    entry.coverUrl = this.coverUrl
    entry.mimeType = this.mimeType
    entry.etag = this.etag
    entry.checksum = this.checksum
    entry.deletedTime = this.deletedTime
    entry.recycleInPath = this.recycleInPath
    entry.recycleSharePath = this.recycleSharePath
    entry.previewRevision = this.previewRevision
    return entry
  }
}

export class RootDirectory {
  personal: FileEntry[] = []
  shared: FileEntry[] = []
  // 个人空间用哪个 root_type 取到的。管理员是 4，普通账号是 2
  // （普通账号读 root_type=4 会返回 1301 Access not allowed）。
  // 根列表按这个值取到之后，在根这一层列目录必须继续用同一个值。
  personalRootType: number = 4
  // 共享空间固定是 3。
  sharedRootType: number = 3
}

export class LoginResult {
  requiresOtp: boolean = false
  message: string = ''

  constructor(requiresOtp: boolean = false, message: string = '') {
    this.requiresOtp = requiresOtp
    this.message = message
  }
}

export class DownloadDescriptor {
  url: string = ''
  fileName: string = ''
  size: number = 0
  headers: Record<string, string> = {}
  etag: string = ''
  checksum: string = ''
  // A descriptor may also represent the short-lived stream URL returned by
  // UGOS's web video pipeline.  Keeping these fields on the descriptor lets
  // the playback path carry the same metadata without changing the durable
  // download contract (which still replaces it with a normal file URL).
  streamType: string = 'file'
  streamTaskId: string = ''
  streamFile: string = ''
  durationMs: number = 0
  width: number = 0
  height: number = 0
  bitrate: number = 0

  constructor(url: string = '', fileName: string = '', size: number = 0,
    headers: Record<string, string> = {}, etag: string = '', checksum: string = '') {
    this.url = url
    this.fileName = fileName
    this.size = size
    this.headers = headers
    this.etag = etag
    this.checksum = checksum
  }
}

export type DownloadTaskStatus = 'queued' | 'downloading' | 'paused' | 'waiting_wifi' | 'waiting_server' |
  'completed' | 'failed'

/**
 * A user-visible download is deliberately not a CacheManager entry.  The
 * staging file lives in filesDir and survives cache cleanup/system reclaim.
 */
@Observed
export class DownloadTaskRecord {
  static copyInto(source: DownloadTaskRecord, result: DownloadTaskRecord): void {
    result.id = source.id
    result.remotePath = source.remotePath
    result.name = source.name
    result.mimeType = source.mimeType
    result.size = source.size
    result.receivedBytes = source.receivedBytes
    result.status = source.status
    result.createdAt = source.createdAt
    result.updatedAt = source.updatedAt
    result.stagingPath = source.stagingPath
    result.finalPath = source.finalPath
    result.destinationRoot = source.destinationRoot
    result.relativePath = source.relativePath
    result.systemTaskId = source.systemTaskId
    result.errorMessage = source.errorMessage
    result.manualMobileResume = source.manualMobileResume
    result.sourceKey = source.sourceKey
    result.sourceScope = source.sourceScope
    result.sourceEtag = source.sourceEtag
    result.sourceChecksum = source.sourceChecksum
    result.resumeValidator = source.resumeValidator
  }

  id: string = ''
  remotePath: string = ''
  name: string = ''
  mimeType: string = ''
  size: number = 0
  receivedBytes: number = 0
  status: DownloadTaskStatus = 'queued'
  createdAt: number = 0
  updatedAt: number = 0
  stagingPath: string = ''
  finalPath: string = ''
  // Absolute local directory selected by the user. Empty keeps the default
  // public system download destination used by normal downloads.
  destinationRoot: string = ''
  // Relative path below destinationRoot. It lets folder copies preserve the
  // remote directory tree while still using the same resumable queue.
  relativePath: string = ''
  systemTaskId: string = ''
  errorMessage: string = ''
  manualMobileResume: boolean = false
  // Stable identity shared by video streaming and the durable download queue.
  sourceKey: string = ''
  sourceScope: string = ''
  sourceEtag: string = ''
  sourceChecksum: string = ''
  resumeValidator: string = ''
}

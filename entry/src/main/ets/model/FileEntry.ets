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
}

export class RootDirectory {
  personal: FileEntry[] = []
  shared: FileEntry[] = []
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

export type DownloadTaskStatus = 'queued' | 'downloading' | 'paused' | 'waiting_wifi' |
  'completed' | 'failed'

/**
 * A user-visible download is deliberately not a CacheManager entry.  The
 * staging file lives in filesDir and survives cache cleanup/system reclaim.
 */
export class DownloadTaskRecord {
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
  // public Download/UGREENlink destination used by normal downloads.
  destinationRoot: string = ''
  // Relative path below destinationRoot. It lets folder copies preserve the
  // remote directory tree while still using the same resumable queue.
  relativePath: string = ''
  systemTaskId: string = ''
  errorMessage: string = ''
  manualMobileResume: boolean = false
  // Stable identity shared by video streaming and the durable download queue.
  sourceKey: string = ''
  sourceEtag: string = ''
  sourceChecksum: string = ''
}

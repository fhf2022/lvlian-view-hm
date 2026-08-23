export class FileEntry {
  name: string = ''
  path: string = ''
  isDirectory: boolean = false
  size: number = 0
  modifiedTime: number = 0
  childCount: number = -1
  rootType: number = 0
  thumbnailUrl: string = ''
  coverUrl: string = ''
  mimeType: string = ''
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

  constructor(url: string = '', fileName: string = '', size: number = 0,
    headers: Record<string, string> = {}) {
    this.url = url
    this.fileName = fileName
    this.size = size
    this.headers = headers
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
}

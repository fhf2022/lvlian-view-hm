export const UGREENLINK_RESOLVE_URL: string = 'https://api.ugnas.com/api/p2p/v2/ta/nodeInfo/byAlias'

export class UgreenEndpoints {
  readonly baseUrl: string

  constructor(baseUrl: string) {
    this.baseUrl = UgreenEndpoints.normalizeBaseUrl(baseUrl)
  }

  rsaCheck(): string {
    return this.baseUrl + '/ugreen/v1/verify/check?token='
  }

  login(): string {
    return this.baseUrl + '/ugreen/v1/verify/login'
  }

  otpLogin(): string {
    return this.baseUrl + '/ugreen/v1/verify/code/login'
  }

  isLogin(): string {
    return this.baseUrl + '/ugreen/v1/verify/is_login'
  }

  listDirectory(): string {
    return this.baseUrl + '/ugreen/v2/filemgr/getDirFileListV2'
  }

  thumbnail(path: string): string {
    return this.baseUrl + '/ugreen/v1/filemgr/thumbnail?path=' + encodeURIComponent(path) +
      '&size_type=1&type=0'
  }

  /**
   * The official UGOS media viewer uses this authenticated source for video
   * playback.  It supports byte ranges without first minting a download-file
   * token; that token route is reserved for explicit durable downloads.
   */
  mediaPlayer(path: string, size: number = 0, modifiedTime: number = 0,
    createdTime: number = 0, intranetShareId: number = 0): string {
    const query = [
      'path=' + encodeURIComponent(path),
      'mtime=' + Math.max(0, Math.floor(modifiedTime)).toString(),
      'ctime=' + Math.max(0, Math.floor(createdTime)).toString(),
      'file_size=' + Math.max(0, Math.floor(size)).toString(),
      'intranet_share_id=' + Math.max(0, Math.floor(intranetShareId)).toString()
    ]
    return this.baseUrl + '/ugreen/v1/filemgr/mediaPlayer?' + query.join('&')
  }

  /** The same server-side HLS preparation endpoints used by the web viewer. */
  streamTranscodeInfo(): string {
    return this.baseUrl + '/ugreen/v2/stream/transcode/web/info'
  }

  streamTranscodePlay(): string {
    return this.baseUrl + '/ugreen/v2/stream/transcode/web/play'
  }

  streamTranscodeM3u8(m3u8File: string, taskId: string, timestamp: number,
    sourceType: number = 1): string {
    const query = [
      'm3u8_file=' + encodeURIComponent(m3u8File),
      'task_id=' + encodeURIComponent(taskId),
      'timestamp=' + Math.max(0, Math.floor(timestamp)).toString(),
      'src_type=' + Math.max(-1, Math.floor(sourceType)).toString()
    ]
    return this.baseUrl + '/ugreen/v2/stream/transcode/web/m3u8?' + query.join('&')
  }

  streamTranscodeClose(): string {
    // This is the endpoint used by web-video-player's sendBeacon cleanup.
    return this.baseUrl + '/ugreen/v2/stream/transcode/web/close'
  }

  detectPermissions(): string {
    return this.baseUrl + '/ugreen/v1/filemgr/detectionPermissions'
  }

  downloadToken(paths: string[]): string {
    const query: string[] = []
    for (const path of paths) {
      query.push('paths=' + encodeURIComponent(path))
    }
    query.push('intranet_share_id=0')
    query.push('coding=true')
    return this.baseUrl + '/ugreen/v2/filemgr/getDownloadToken?' + query.join('&')
  }

  downloadFile(token: string): string {
    return this.baseUrl + '/ugreen/v2/filemgr/downloadFile?token=' + encodeURIComponent(token)
  }

  downloadLink(path: string): string {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path
    }
    if (path.startsWith('//')) {
      return 'https:' + path
    }
    if (path.startsWith('/')) {
      return this.baseUrl + path
    }
    return this.baseUrl + '/' + path
  }

  createFolder(): string {
    return this.baseUrl + '/ugreen/v2/filemgr/createFolder'
  }

  rename(): string {
    return this.baseUrl + '/ugreen/v2/filemgr/rename'
  }

  copyOrMovePaths(): string {
    return this.baseUrl + '/ugreen/v2/filemgr/cpOrMvPath'
  }

  deletePaths(): string {
    return this.baseUrl + '/ugreen/v2/filemgr/delPaths'
  }

  static normalizeBaseUrl(url: string): string {
    const normalized = url.includes('://') ? url : 'https://' + url
    return normalized.replace(/\/+$/, '')
  }
}

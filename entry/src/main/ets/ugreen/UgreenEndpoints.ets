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

  copyPaths(): string {
    return this.baseUrl + '/ugreen/v2/filemgr/copy'
  }

  movePaths(): string {
    return this.baseUrl + '/ugreen/v2/filemgr/move'
  }

  deletePaths(): string {
    return this.baseUrl + '/ugreen/v2/filemgr/delPaths'
  }

  static normalizeBaseUrl(url: string): string {
    const normalized = url.includes('://') ? url : 'https://' + url
    return normalized.replace(/\/+$/, '')
  }
}

import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { FileEntry, RootDirectory, LoginResult, DownloadDescriptor } from '../model/FileEntry'
import { UgreenSession } from '../model/Session'
import { SessionStore } from '../core/session/SessionStore'
import { UgreenCrypto } from '../core/crypto/UgreenCrypto'
import { HttpTransport } from '../core/network/HttpTransport'
import { HttpResult, JsonObject } from '../core/network/HttpTypes'
import { UGREENLINK_RESOLVE_URL, UgreenEndpoints } from './UgreenEndpoints'
import { UgreenError, UgreenErrorKind } from './UgreenErrors'

interface PendingLogin {
  username: string
  password: string
}

export interface UgreenDirectoryPage {
  pageIndex: number
  entries: FileEntry[]
  totalCount: number
  hasMore: boolean
}

export class UgreenRemoteClient {
  private static readonly DIRECTORY_PAGE_SIZE: number = 200
  // Metadata-only indexing must cover large photo directories. The guard is
  // still finite so a broken endpoint cannot create an endless page loop.
  private static readonly MAX_DIRECTORY_PAGES: number = 1000
  private transport: HttpTransport
  private sessionStore: SessionStore
  private endpoints: UgreenEndpoints | null = null
  private pendingLogin: PendingLogin | null = null
  private reconnectCredentials: PendingLogin | null = null
  private reconnectPromise: Promise<boolean> | null = null

  constructor(transport: HttpTransport = new HttpTransport(), sessionStore: SessionStore = new SessionStore()) {
    this.transport = transport
    this.sessionStore = sessionStore
  }

  /**
   * Supplies credentials that the user explicitly chose to remember. This is
   * used only to rebuild an expired session; the active token is still kept in
   * memory and is never persisted here.
   */
  setReconnectCredentials(username: string, password: string): void {
    const cleanUsername = username.trim()
    if (cleanUsername.length === 0 || password.length === 0) {
      return
    }
    this.reconnectCredentials = { username: cleanUsername, password: password }
  }

  clearSession(): void {
    this.sessionStore.clear()
    this.pendingLogin = null
    this.reconnectCredentials = null
    this.reconnectPromise = null
  }

  /** Reconnect once for transient network/auth failures. */
  async withReconnect<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await operation()
    } catch (error) {
      if (!this.shouldReconnect(error)) {
        throw error as Error
      }
      if (!await this.reconnect()) {
        throw error as Error
      }
      return await operation()
    }
  }

  cacheScope(): string {
    const session = this.sessionStore.get()
    if (session === null) {
      return ''
    }
    const identity = session.uid.length > 0 ? session.uid : session.tokenId
    return session.baseUrl + '|' + identity
  }

  async resolve(ugreenLinkId: string): Promise<string> {
    const alias = ugreenLinkId.trim()
    if (alias.length === 0) {
      throw new UgreenError(UgreenErrorKind.API_CHANGED, '请输入 UGREENlink ID')
    }
    const resolveBody: JsonObject = {}
    resolveBody['alias'] = alias
    const response = await this.transport.requestJson(UGREENLINK_RESOLVE_URL, http.RequestMethod.POST, resolveBody)
    const data = this.successData(response.body, 'UGREENlink 解析失败')
    const relayDomain = this.stringValue(data['relayDomain'])
    if (relayDomain.length === 0) {
      throw new UgreenError(UgreenErrorKind.API_CHANGED, '解析结果缺少远程域名')
    }
    const baseUrl = relayDomain.includes('://') ? relayDomain : 'https://' + alias + '.' + relayDomain
    this.endpoints = new UgreenEndpoints(baseUrl)
    return this.endpoints.baseUrl
  }

  async login(username: string, password: string): Promise<LoginResult> {
    const cleanUsername = username.trim()
    if (cleanUsername.length === 0 || password.length === 0) {
      throw new UgreenError(UgreenErrorKind.LOGIN_FAILED, '请输入 NAS 用户名和密码')
    }
    const urls = this.requireEndpoints()
    const rsaBody: JsonObject = {}
    rsaBody['username'] = cleanUsername
    const rsaResponse = await this.transport.requestJson(urls.rsaCheck(), http.RequestMethod.POST, rsaBody)
    this.successData(rsaResponse.body, '获取 RSA 公钥失败')
    const rsaToken = this.headerValue(rsaResponse.headers, 'x-rsa-token')
    if (rsaToken.length === 0) {
      throw new UgreenError(UgreenErrorKind.API_CHANGED, '登录接口没有返回 RSA 公钥')
    }
    const encryptedPassword = await UgreenCrypto.encryptBase64(password, rsaToken)
    const pending: PendingLogin = { username: cleanUsername, password: password }
    this.pendingLogin = pending
    const loginRequestBody: JsonObject = {}
    loginRequestBody['username'] = cleanUsername
    loginRequestBody['password'] = encryptedPassword
    loginRequestBody['otp'] = true
    loginRequestBody['is_simple'] = true
    const loginResponse = await this.transport.requestJson(urls.login(), http.RequestMethod.POST, loginRequestBody)
    const loginResponseBody = loginResponse.body
    const loginCode = this.numberValue(loginResponseBody['code'])
    const loginData = this.asRecord(loginResponseBody['data'])
    if (this.needsOtp(loginResponseBody, loginData)) {
      return new LoginResult(true, '需要输入 6 位验证码')
    }
    if (loginCode !== 200) {
      this.pendingLogin = null
      throw new UgreenError(UgreenErrorKind.LOGIN_FAILED,
        this.stringValue(loginResponseBody['msg'], 'NAS 登录失败'), 0, loginCode)
    }
    const tokenId = this.stringValue(loginData['token_id'])
    const token = this.stringValue(loginData['token'])
    const publicKey = this.stringValue(loginData['public_key'])
    if (tokenId.length === 0 || token.length === 0 || publicKey.length === 0) {
      this.pendingLogin = null
      throw new UgreenError(UgreenErrorKind.API_CHANGED, '登录成功但会话字段不完整')
    }
    this.sessionStore.set(new UgreenSession(
      urls.baseUrl,
      tokenId,
      token,
      this.stringValue(loginData['uid']),
      publicKey
    ))
    this.reconnectCredentials = pending
    this.pendingLogin = null
    return new LoginResult(false, '登录成功')
  }

  async verifyOtp(code: string, trustDevice: boolean = false): Promise<LoginResult> {
    const urls = this.requireEndpoints()
    const cleanCode = code.trim()
    if (cleanCode.length !== 6) {
      throw new UgreenError(UgreenErrorKind.OTP_REQUIRED, '请输入 6 位验证码')
    }
    const pending = this.pendingLogin
    const body: JsonObject = {}
    body['code'] = cleanCode
    body['trust'] = trustDevice
    if (pending !== null) {
      body['username'] = pending.username
    }
    const response = await this.transport.requestJson(urls.otpLogin(), http.RequestMethod.POST, body)
    const data = this.successData(response.body, '验证码登录失败')
    const tokenId = this.stringValue(data['token_id'])
    const token = this.stringValue(data['token'])
    const publicKey = this.stringValue(data['public_key'])
    if (tokenId.length === 0 || token.length === 0 || publicKey.length === 0) {
      throw new UgreenError(UgreenErrorKind.API_CHANGED, '验证码登录成功但会话字段不完整')
    }
    this.sessionStore.set(new UgreenSession(
      urls.baseUrl,
      tokenId,
      token,
      this.stringValue(data['uid']),
      publicKey
    ))
    if (pending !== null) {
      this.reconnectCredentials = pending
    }
    this.pendingLogin = null
    return new LoginResult(false, '登录成功')
  }

  async getRoot(): Promise<RootDirectory> {
    const root = new RootDirectory()
    const result = await Promise.all([
      this.list('', 4),
      this.list('', 3)
    ])
    root.personal = result[0].filter((item: FileEntry) => item.isDirectory)
    root.shared = result[1].filter((item: FileEntry) => item.isDirectory)
    return root
  }

  async list(path: string, rootType: number = 4): Promise<FileEntry[]> {
    const pages = await this.listPages(path, rootType)
    const result: FileEntry[] = []
    for (const page of pages) {
      for (const entry of page.entries) {
        result.push(entry)
      }
    }
    this.sortEntries(result)
    return result
  }

  async listPages(path: string, rootType: number = 4): Promise<UgreenDirectoryPage[]> {
    const pages: UgreenDirectoryPage[] = []
    for (let pageIndex = 1; pageIndex <= UgreenRemoteClient.MAX_DIRECTORY_PAGES; pageIndex++) {
      const page = await this.listPage(path, rootType, pageIndex)
      pages.push(page)
      if (!page.hasMore || page.entries.length === 0) {
        break
      }
    }
    return pages
  }

  async listPage(path: string, rootType: number, pageIndex: number): Promise<UgreenDirectoryPage> {
    return await this.withReconnect(() => this.listPageOnce(path, rootType, pageIndex))
  }

  private async listPageOnce(path: string, rootType: number, pageIndex: number): Promise<UgreenDirectoryPage> {
    const urls = this.requireEndpoints()
    const headers = await this.authHeaders()
    const requestPath = this.normalizePath(path)
    // UGOS uses root_type=4/3 to enumerate the two root collections. Once a
    // concrete path is supplied, the web/Node client switches to root_type=3
    // for normal file-manager traversal, including personal folders.
    const effectiveRootType = requestPath.length > 0 ? 3 : rootType
    const listBody: JsonObject = {}
    listBody['path'] = requestPath
    listBody['limit'] = UgreenRemoteClient.DIRECTORY_PAGE_SIZE
    listBody['page'] = pageIndex
    listBody['is_shield_recycle'] = false
    listBody['data_type'] = 0
    listBody['left_no_page_show'] = false
    listBody['left_count'] = 5000
    listBody['sort_type'] = 1
    listBody['reverse'] = false
    listBody['permission'] = 4
    listBody['root_type'] = effectiveRootType
    const listHeaders = this.withHeaders(headers, 'content-type', 'application/json')
    listHeaders['referer'] = urls.baseUrl + '/filemgr/?_filemgr=a58981e8'
    const response = await this.transport.requestJson(urls.listDirectory(), http.RequestMethod.POST, listBody, listHeaders)
    const data = this.successData(response.body, '目录读取失败')
    const rightFiles = this.asRecord(data['right_files'])
    const files = rightFiles['files']
    if (!(files instanceof Array)) {
      return {
        pageIndex: pageIndex,
        entries: [],
        totalCount: 0,
        hasMore: false
      }
    }
    const result: FileEntry[] = []
    for (const value of files as Object[]) {
      const raw = this.asRecord(value)
      const entry = new FileEntry()
      entry.name = this.stringValue(raw['name'], '未命名')
      const remotePath = this.firstString(raw, ['path', 'full_path', 'file_path', 'filepath'])
      entry.path = this.normalizePath(remotePath.length > 0 ? remotePath : this.joinPath(requestPath, entry.name))
      entry.isDirectory = this.isDirectory(raw)
      entry.size = this.firstNumber(raw, ['size', 'file_size', 'fileSize', 'bytes', 'length'])
      entry.modifiedTime = this.firstNumber(raw, ['mtime', 'modified_time', 'modifiedTime', 'last_modified'])
      entry.createdTime = this.firstNumber(raw, ['ctime', 'create_time', 'created_time', 'created_at'])
      entry.childCount = this.directoryChildCount(raw)
      entry.rootType = effectiveRootType
      entry.intranetShareId = this.firstNumber(raw, ['intranet_share_id', 'intranetShareId'])
      entry.thumbnailUrl = this.remotePreviewUrl(urls, raw, [
        'thumbnail_url', 'thumbnailUrl', 'thumb_url', 'thumbUrl', 'thumbnail', 'thumb',
        'preview_url', 'previewUrl', 'preview', 'poster_url', 'posterUrl', 'poster',
        'small_url', 'smallUrl', 'small', 'file_thumbnail', 'fileThumbnail', 'file_thumb', 'fileThumb'
      ])
      entry.coverUrl = this.remotePreviewUrl(urls, raw, [
        'cover_url', 'coverUrl', 'cover', 'album_art_url', 'albumArtUrl', 'album_art', 'albumArt',
        'artwork_url', 'artworkUrl', 'artwork', 'album_cover', 'albumCover', 'song_cover', 'songCover'
      ])
      entry.mimeType = this.firstString(raw, ['mime_type', 'mimetype', 'content_type', 'type_name'])
      entry.etag = this.firstString(raw, ['etag', 'e_tag', 'entity_tag', 'entityTag'])
      entry.checksum = this.firstString(raw, [
        'checksum', 'hash', 'md5', 'sha256', 'content_hash', 'contentHash'
      ])
      result.push(entry)
    }
    this.sortEntries(result)
    let totalCount = this.firstCount(rightFiles, [
      'total', 'total_count', 'count', 'file_count', 'items_count'
    ])
    if (totalCount < 0) {
      totalCount = this.firstCount(data, [
        'total', 'total_count', 'count', 'file_count', 'items_count'
      ])
    }
    const hasMore = totalCount >= 0
      ? pageIndex * UgreenRemoteClient.DIRECTORY_PAGE_SIZE < totalCount
      : result.length >= UgreenRemoteClient.DIRECTORY_PAGE_SIZE
    return {
      pageIndex: pageIndex,
      entries: result,
      totalCount: totalCount,
      hasMore: hasMore
    }
  }

  async download(path: string): Promise<DownloadDescriptor> {
    return await this.withReconnect(() => this.downloadOnce(path))
  }

  /**
   * Returns the same authenticated mediaPlayer source used by the official
   * UGOS viewer.  Unlike download(), this deliberately does not mint a
   * download-file token: AVPlayer needs a seekable Range source while the
   * user is only viewing the remote movie.
   */
  async mediaPlayerDescriptor(entry: FileEntry): Promise<DownloadDescriptor> {
    return await this.withReconnect(() => this.mediaPlayerDescriptorOnce(entry))
  }

  private async mediaPlayerDescriptorOnce(entry: FileEntry): Promise<DownloadDescriptor> {
    const urls = this.requireEndpoints()
    const headers = await this.authHeaders()
    headers['referer'] = urls.baseUrl + '/filemgr/?_filemgr=a58981e8'
    const createdTime = entry.createdTime > 0 ? entry.createdTime : entry.modifiedTime
    const url = urls.mediaPlayer(entry.path, entry.size, entry.modifiedTime,
      createdTime, entry.intranetShareId)
    return new DownloadDescriptor(url, entry.name, entry.size, headers,
      entry.etag, entry.checksum)
  }

  /**
   * Prepare the server-side HLS source used by the UGOS web video viewer.
   *
   * The web client first asks for media information, then creates one HLS
   * playlist for the selected quality/audio track.  The playlist and its
   * segments are consumed directly by AVPlayer, so the application never
   * needs to assemble a sparse MP4 while the decoder is already reading it.
   * A caller can fall back to mediaPlayerDescriptor() when an older NAS has
   * no transcode worker available.
   */
  async streamDescriptor(entry: FileEntry): Promise<DownloadDescriptor> {
    return await this.withReconnect(() => this.streamDescriptorOnce(entry))
  }

  /** Stop one server-side HLS producer when the viewer is closed. */
  async closeStreamTask(taskId: string, sourceType: number = 1): Promise<void> {
    const cleanTaskId = taskId.trim()
    if (cleanTaskId.length === 0) {
      return
    }
    await this.withReconnect(() => this.closeStreamTaskOnce(cleanTaskId, sourceType))
  }

  private async closeStreamTaskOnce(taskId: string, sourceType: number): Promise<void> {
    const urls = this.requireEndpoints()
    const sourceHeaders = await this.authHeaders()
    sourceHeaders['referer'] = urls.baseUrl + '/filemgr/?_filemgr=a58981e8'
    const headers = this.withHeaders(sourceHeaders, 'content-type', 'application/json')
    const body: JsonObject = {}
    body['task_id'] = taskId
    body['timestamp'] = Date.now().toString()
    body['src_type'] = Math.max(-1, Math.floor(sourceType))
    await this.transport.requestJson(urls.streamTranscodeClose(), http.RequestMethod.POST, body, headers)
  }

  private async streamDescriptorOnce(entry: FileEntry): Promise<DownloadDescriptor> {
    const urls = this.requireEndpoints()
    const sourceHeaders = await this.authHeaders()
    sourceHeaders['referer'] = urls.baseUrl + '/filemgr/?_filemgr=a58981e8'
    const headers = this.withHeaders(sourceHeaders, 'content-type', 'application/json')
    const timestamp = Date.now()
    const taskId = this.newStreamTaskId(timestamp)
    let descriptorReady = false
    try {
      const common: JsonObject = {}
      common['task_id'] = taskId
      common['timestamp'] = timestamp.toString()
      common['src_type'] = 1
      const infoBody: JsonObject = {}
      for (const key of Object.keys(common)) {
        infoBody[key] = common[key]
      }
      infoBody['video_path'] = entry.path
      // Local NAS paths use the NAS transcode service.  The web client only
      // enables this flag for cloud/net-disk direct links.
      infoBody['is_net_disk_direct'] = false
      const infoResponse = await this.transport.requestJson(urls.streamTranscodeInfo(),
        http.RequestMethod.POST, infoBody, headers)
      const info = this.successData(infoResponse.body, '获取视频流信息失败')
      const transcodeable = info['transcodeable']
      if (!(transcodeable instanceof Array) || transcodeable.length === 0) {
        throw new UgreenError(UgreenErrorKind.UNKNOWN, '视频没有可用的流媒体清晰度')
      }

      const firstQuality = transcodeable[0] as JsonObject
      const quality = this.firstString(firstQuality, ['resolution', 'value'])
      const redirLink = this.stringValue(info['redir_link'])
      const videoName = this.queryValue(redirLink, 'video_name')
      if (quality.length === 0 || videoName.length === 0) {
        throw new UgreenError(UgreenErrorKind.API_CHANGED, '视频流信息缺少播放地址')
      }
      const audios = info['audios']
      let audioIndex = -1
      if (audios instanceof Array && audios.length > 0) {
        const firstAudio = audios[0] as JsonObject
        audioIndex = this.firstNumber(firstAudio, ['id', 'index'])
        if (audioIndex <= 0) {
          audioIndex = -1
        }
      }
      const m3u8File = videoName + '_' + quality + '.m3u8'
      const playBody: JsonObject = {}
      for (const key of Object.keys(common)) {
        playBody[key] = common[key]
      }
      playBody['m3u8_file'] = m3u8File
      playBody['regen'] = 1
      playBody['subtitle_index'] = -1
      playBody['audio_index'] = audioIndex
      // HarmonyOS devices decode HEVC in AVPlayer, but requesting the H.264
      // rendition keeps the fallback compatible with older device codecs.  The
      // browser chooses this flag from MediaSource support; native playback has
      // no reason to force a codec the device may not expose.
      playBody['prefer_h265'] = false
      const playResponse = await this.transport.requestJson(urls.streamTranscodePlay(),
        http.RequestMethod.POST, playBody, headers)
      const play = this.successData(playResponse.body, '创建视频流失败')
      const streamUrl = urls.streamTranscodeM3u8(m3u8File, taskId, Date.now(), 1)
      const descriptor = new DownloadDescriptor(streamUrl, entry.name, entry.size, sourceHeaders,
        entry.etag, entry.checksum)
      descriptor.streamType = 'hls'
      descriptor.streamTaskId = taskId
      descriptor.streamFile = m3u8File
      descriptor.durationMs = this.firstNumber(info, ['duration', 'duration_ms'])
      descriptor.width = this.firstNumber(info, ['width'])
      descriptor.height = this.firstNumber(info, ['height'])
      descriptor.bitrate = this.firstNumber(play, ['bitrate_bps', 'bitrate'])
      descriptorReady = true
      console.info('[UgreenVideo] HLS stream prepared path=' + entry.path +
        ' quality=' + quality + ' duration=' + descriptor.durationMs.toString())
      return descriptor
    } finally {
      if (!descriptorReady) {
        // The web client sends a close beacon when preparation fails as well.
        // Do the same before falling back to mediaPlayer so a failed 9404 or
        // malformed response does not leave a producer running on the NAS.
        try {
          await this.closeStreamTaskOnce(taskId, 1)
        } catch (error) {
          console.warn('[UgreenVideo] close failed HLS preparation task: ' + String(error))
        }
      }
    }
  }

  private async downloadOnce(path: string): Promise<DownloadDescriptor> {
    const urls = this.requireEndpoints()
    const sessionHeaders = await this.authHeaders()
    // Downloads are issued from the web file-manager session. Some relay
    // gateways validate the referer on the permission/token requests and on
    // the signed file request, while thumbnail requests already carried it.
    // Keep the original-file path in the same authenticated context.
    sessionHeaders['referer'] = urls.baseUrl + '/filemgr/?_filemgr=a58981e8'
    const permissionBody: JsonObject = {}
    permissionBody['paths'] = [path]
    permissionBody['type'] = 4
    permissionBody['intranet_share_id'] = 0
    const permissionHeaders = this.withHeaders(sessionHeaders, 'content-type', 'application/json')
    let permissionResponse: HttpResult<JsonObject>
    try {
      permissionResponse = await this.transport.requestJson(urls.detectPermissions(), http.RequestMethod.POST,
        permissionBody, permissionHeaders)
    } catch (error) {
      console.warn('[UgreenDownload] permission request failed for ' + path + ' :: ' + String(error))
      throw error as Error
    }
    this.successData(permissionResponse.body, '没有文件下载权限')
    let tokenResponse: HttpResult<JsonObject>
    try {
      tokenResponse = await this.transport.requestJson(urls.downloadToken([path]), http.RequestMethod.GET,
        undefined, sessionHeaders)
    } catch (error) {
      console.warn('[UgreenDownload] token request failed for ' + path + ' :: ' + String(error))
      throw error as Error
    }
    const tokenData = this.successData(tokenResponse.body, '获取下载令牌失败')
    // Current UGOS returns data.dl_token and expects a second
    // v2/filemgr/downloadFile?token=... request.  A few older firmware
    // versions returned a ready-to-use dl_url, so keep that form compatible.
    const downloadPath = this.stringValue(tokenData['dl_url'])
    const downloadToken = this.firstString(tokenData,
      ['dl_token', 'download_token', 'downloadToken', 'token'])
    const downloadUrl = downloadPath.length > 0 ? urls.downloadLink(downloadPath) :
      (downloadToken.length > 0 ? urls.downloadFile(downloadToken) : '')
    if (downloadUrl.length === 0) {
      throw new UgreenError(UgreenErrorKind.API_CHANGED, '下载接口没有返回文件地址或令牌')
    }
    const descriptor = new DownloadDescriptor(
      downloadUrl,
      this.fileName(path),
      this.firstNumber(tokenData, ['size', 'file_size', 'fileSize', 'bytes', 'length']),
      sessionHeaders,
      this.firstString(tokenData, ['etag', 'e_tag', 'entity_tag', 'entityTag']),
      this.firstString(tokenData, [
        'checksum', 'hash', 'md5', 'sha256', 'content_hash', 'contentHash'
      ])
    )
    return descriptor
  }

  async thumbnail(entry: FileEntry): Promise<DownloadDescriptor> {
    const candidates = await this.thumbnailCandidates(entry)
    return candidates.length > 0 ? candidates[0] : new DownloadDescriptor()
  }

  async thumbnailCandidates(entry: FileEntry): Promise<DownloadDescriptor[]> {
    return await this.withReconnect(() => this.thumbnailCandidatesOnce(entry))
  }

  private async thumbnailCandidatesOnce(entry: FileEntry): Promise<DownloadDescriptor[]> {
    const urls = this.requireEndpoints()
    const headers = await this.authHeaders()
    const thumbnailHeaders = this.withHeaders(headers, 'accept', 'image/*')
    // The web file manager sends this referer for preview requests. Keep the
    // binary request in the same authenticated context instead of accepting
    // a successful HTML/JSON error body as an image.
    thumbnailHeaders['referer'] = urls.baseUrl + '/filemgr/?_filemgr=a58981e8'
    const result: DownloadDescriptor[] = []
    // The file manager's thumbnail endpoint is the authoritative image
    // route. Some list responses expose preview_url/thumbnail_url values
    // that return a successful non-image body for remote sessions.
    result.push(new DownloadDescriptor(urls.thumbnail(entry.path),
      entry.name + '.thumbnail', 0, thumbnailHeaders))
    const previewPath = this.previewPath(entry)
    const previewUrl = previewPath.length > 0 ? urls.downloadLink(previewPath) : ''
    if (previewUrl.length > 0 && previewUrl !== result[0].url) {
      result.push(new DownloadDescriptor(previewUrl, entry.name + '.thumbnail', 0, thumbnailHeaders))
    }
    return result
  }

  async rename(path: string, newName: string): Promise<void> {
    await this.withReconnect(async (): Promise<void> => {
      const urls = this.requireEndpoints()
      const headers = this.withHeaders(await this.authHeaders(), 'content-type', 'application/json')
      const body: JsonObject = {}
      body['path'] = path
      body['new_name'] = newName
      const response = await this.transport.requestJson(urls.rename(), http.RequestMethod.POST, body, headers)
      this.successData(response.body, '文件重命名失败')
    })
  }

  async copy(paths: string[], targetPath: string): Promise<void> {
    await this.withReconnect(async (): Promise<void> => {
      const urls = this.requireEndpoints()
      const headers = this.withHeaders(await this.authHeaders(), 'content-type', 'application/json')
      const body: JsonObject = {}
      body['paths'] = paths
      body['target_path'] = targetPath
      const response = await this.transport.requestJson(urls.copyPaths(), http.RequestMethod.POST, body, headers)
      this.successData(response.body, '文件复制失败')
    })
  }

  async move(paths: string[], targetPath: string): Promise<void> {
    await this.withReconnect(async (): Promise<void> => {
      const urls = this.requireEndpoints()
      const headers = this.withHeaders(await this.authHeaders(), 'content-type', 'application/json')
      const body: JsonObject = {}
      body['paths'] = paths
      body['target_path'] = targetPath
      const response = await this.transport.requestJson(urls.movePaths(), http.RequestMethod.POST, body, headers)
      this.successData(response.body, '文件移动失败')
    })
  }

  async createFolder(path: string): Promise<void> {
    await this.withReconnect(async (): Promise<void> => {
      const urls = this.requireEndpoints()
      const headers = this.withHeaders(await this.authHeaders(), 'content-type', 'application/json')
      const body: JsonObject = {}
      body['path'] = path
      body['no_recursive_creation'] = true
      const response = await this.transport.requestJson(urls.createFolder(),
        http.RequestMethod.POST, body, headers)
      this.successData(response.body, '文件夹创建失败')
    })
  }

  async trash(path: string): Promise<void> {
    await this.withReconnect(async (): Promise<void> => {
      const urls = this.requireEndpoints()
      const headers = this.withHeaders(await this.authHeaders(), 'content-type', 'application/json')
      const body: JsonObject = {}
      body['paths'] = [path]
      body['forever'] = false
      const response = await this.transport.requestJson(urls.deletePaths(), http.RequestMethod.POST, body, headers)
      this.successData(response.body, '文件删除失败')
    })
  }

  private async reconnect(): Promise<boolean> {
    if (this.reconnectCredentials === null) {
      return false
    }
    if (this.reconnectPromise !== null) {
      return await this.reconnectPromise
    }
    const credentials = this.reconnectCredentials
    const task = this.performReconnect(credentials)
    this.reconnectPromise = task
    try {
      return await task
    } finally {
      if (this.reconnectPromise === task) {
        this.reconnectPromise = null
      }
    }
  }

  private async performReconnect(credentials: PendingLogin): Promise<boolean> {
    for (let attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, 600)
        })
      }
      try {
        const result = await this.login(credentials.username, credentials.password)
        if (!result.requiresOtp) {
          return true
        }
        return false
      } catch (_) {
        // A second attempt covers a short Wi-Fi/mobile-network handoff.
      }
    }
    return false
  }

  private shouldReconnect(error: Object): boolean {
    if (!(error instanceof UgreenError)) {
      return false
    }
    if (error.kind === UgreenErrorKind.AUTH_EXPIRED) {
      return true
    }
    if (error.status === 401 || error.status === 403 || error.status === 408 || error.status === 429 ||
      error.apiCode === 401 || error.apiCode === 403 || error.apiCode === 419) {
      return true
    }
    return error.kind === UgreenErrorKind.NETWORK &&
      (error.status === 0 || error.status >= 500)
  }

  private async authHeaders(): Promise<Record<string, string>> {
    const session = this.sessionStore.get()
    if (session === null) {
      throw new UgreenError(UgreenErrorKind.AUTH_EXPIRED, '登录状态已失效，请重新登录')
    }
    return {
      'x-ugreen-security-key': session.tokenId,
      'x-ugreen-token': await UgreenCrypto.encryptBase64(session.token, session.publicKey)
    }
  }

  // Protocol matches the UGOS web client's createUploadData/uploadWebFileStream.
  async prepareUpload(dir: string, name: string, uuid: string, size: number,
    changed: number): Promise<boolean> {
    const boundary = 'UGREENlink' + uuid.replace(/[^a-zA-Z0-9]/g, '')
    const fields: Record<string, string> = { 'uuid': uuid, 'dir': dir, 'filename': name,
      'action_type': '0', 'size': String(size), 'begin_size': '0', 'current_size': '0',
      'change_time': String(changed), 'resume': 'true', 'first_request': 'true' }
    let form = ''
    for (const key of Object.keys(fields)) {
      form += '--' + boundary + '\r\nContent-Disposition: form-data; name="' + key +
        '"\r\n\r\n' + fields[key] + '\r\n'
    }
    form += '--' + boundary + '\r\nContent-Disposition: form-data; name="file"; filename="' +
      encodeURIComponent(name) + '"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--' + boundary + '--\r\n'
    const headers = await this.authHeaders()
    headers['Content-Type'] = 'multipart/form-data; boundary=' + boundary
    const bytes = new util.TextEncoder().encodeInto(form)
    const data = this.successData(await this.transport.postUpload(
      this.requireEndpoints().baseUrl + '/ugreen/v1/filemgr/fileUpload', bytes.buffer as ArrayBuffer,
      headers), '上传预创建失败')
    return Boolean(data['result'])
  }

  async uploadOffset(dir: string, uuid: string, size: number): Promise<number> {
    const response = await this.transport.requestJson(this.requireEndpoints().baseUrl +
      '/ugreen/v1/filemgr/getUpdateTmpInfo?dir=' + encodeURIComponent(dir) +
      '&uuid=' + encodeURIComponent(uuid) + '&size=' + size, http.RequestMethod.GET,
      undefined, await this.authHeaders())
    const count = Number(this.successData(response.body, '查询上传断点失败')['result'] || 0)
    if (!Number.isFinite(count) || count < 0 || count > size) { throw new Error('上传断点无效') }
    // UGOS's browser uploader replays the last acknowledged byte on resume.
    return Math.max(0, count - 1)
  }

  async uploadChunk(dir: string, name: string, uuid: string, size: number,
    changed: number, offset: number, bytes: ArrayBuffer): Promise<void> {
    const params: JsonObject = { 'uuid': uuid, 'file_name': encodeURIComponent(name), 'action_type': 0,
      'size': size, 'current_size': bytes.byteLength, 'resume': true, 'dir': encodeURIComponent(dir),
      'change_time': changed, 'is_live_photo': false, 'first_request': false, 'begin_size': offset }
    const headers = await this.authHeaders()
    headers['Content-Type'] = 'application/octet-stream'
    headers['ug-param'] = JSON.stringify(params)
    headers['Content-Disposition'] = 'attachment; filename="' + encodeURIComponent(name) + '"'
    this.successData(await this.transport.postUpload(this.requireEndpoints().baseUrl +
      '/ugreen/v1/filemgr/fileUploadV2', bytes, headers), '上传分块失败')
  }

  async removeUploadTemporary(dir: string, uuid: string): Promise<void> {
    const headers = await this.authHeaders()
    headers['Content-Type'] = 'application/json'
    const item: JsonObject = { 'dir': dir, 'uuid': uuid }
    const items: JsonObject[] = [item]
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(items))
    this.successData(await this.transport.postUpload(this.requireEndpoints().baseUrl +
      '/ugreen/v1/filemgr/delUpTemFile', bytes.buffer as ArrayBuffer, headers), '清理上传断点失败')
  }

  private requireEndpoints(): UgreenEndpoints {
    const value = this.endpoints
    if (value === null) {
      throw new UgreenError(UgreenErrorKind.API_CHANGED, '请先解析 UGREENlink ID')
    }
    return value
  }

  private successData(body: JsonObject, context: string): JsonObject {
    const code = this.numberValue(body['code'])
    if (code !== 200) {
      const message = this.stringValue(body['msg'], context)
      const kind = this.isAuthenticationFailure(code, message)
        ? UgreenErrorKind.AUTH_EXPIRED : UgreenErrorKind.UNKNOWN
      throw new UgreenError(kind, message, 0, code)
    }
    return this.asRecord(body['data'])
  }

  /**
   * UGOS can report an expired session as HTTP 200 with a non-200 business
   * code. The relay has used several English messages for this condition,
   * including the misspelled "token cannnot be empty". Keep the matching
   * narrow enough that ordinary API errors still reach the UI unchanged.
   */
  private isAuthenticationFailure(code: number, message: string): boolean {
    if (code === 401 || code === 403 || code === 419) {
      return true
    }
    const normalized = message.toLowerCase()
    const expired = normalized.includes('expired') || normalized.includes('experied') ||
      normalized.includes('过期') || normalized.includes('失效')
    if ((normalized.includes('login') || normalized.includes('session') ||
      normalized.includes('authentication')) && expired) {
      return true
    }
    if (normalized.includes('please login again') || normalized.includes('please log in again') ||
      normalized.includes('请重新登录')) {
      return true
    }
    if (!normalized.includes('token')) {
      return normalized.includes('登录状态') || normalized.includes('会话失效') ||
        normalized.includes('未登录') || normalized.includes('not logged in')
    }
    return normalized.includes('empty') || normalized.includes('expired') ||
      normalized.includes('invalid') || normalized.includes('missing') ||
      normalized.includes('失效') || normalized.includes('过期')
  }

  private needsOtp(body: JsonObject, data: JsonObject): boolean {
    if (this.booleanValue(body['need_otp']) || this.booleanValue(body['otp_required']) ||
      this.booleanValue(data['need_otp']) || this.booleanValue(data['otp_required'])) {
      return true
    }
    const text = (this.stringValue(body['msg']) + ' ' + this.stringValue(data['msg'])).toLowerCase()
    return text.includes('otp') || text.includes('verification code') || text.includes('verify code') ||
      text.includes('验证码')
  }

  private asRecord(value: Object | undefined): JsonObject {
    if (value === undefined || value === null) {
      return {}
    }
    return value as JsonObject
  }

  private stringValue(value: Object | undefined, fallback: string = ''): string {
    if (typeof value === 'string') {
      return value
    }
    if (value !== undefined && value !== null) {
      return String(value)
    }
    return fallback
  }

  private numberValue(value: Object | undefined): number {
    if (typeof value === 'number') {
      return value
    }
    if (typeof value === 'string') {
      return Number(value)
    }
    return 0
  }

  private newStreamTaskId(timestamp: number): string {
    // Mirror the web player's task identity exactly: a UUID between the PC
    // prefix and the millisecond timestamp.  The transcode service uses this
    // value to associate info/play/m3u8 requests with one producer session.
    return 'PC&' + util.generateRandomUUID() + '&' + timestamp.toString()
  }

  private queryValue(url: string, key: string): string {
    const question = url.indexOf('?')
    if (question < 0) {
      return ''
    }
    const query = url.substring(question + 1).split('&')
    for (const item of query) {
      const equals = item.indexOf('=')
      if (equals <= 0) {
        continue
      }
      const name = decodeURIComponent(item.substring(0, equals))
      if (name !== key) {
        continue
      }
      try {
        return decodeURIComponent(item.substring(equals + 1))
      } catch (_) {
        return item.substring(equals + 1)
      }
    }
    return ''
  }

  private firstNumber(raw: JsonObject, keys: string[]): number {
    for (const key of keys) {
      const rawValue = raw[key]
      if (rawValue !== undefined && rawValue !== null &&
        !(typeof rawValue === 'string' && rawValue.trim().length === 0)) {
        const value = this.numberValue(rawValue)
        if (value > 0 && Number.isFinite(value)) {
          return Math.floor(value)
        }
      }
    }
    // Some firmware puts file metadata under a nested info object. Keep the
    // fallback narrow so generic counts do not accidentally become file size.
    for (const containerName of ['metadata', 'meta', 'file_info', 'fileInfo', 'media', 'extra']) {
      const container = this.asRecord(raw[containerName])
      for (const key of keys) {
        const rawValue = container[key]
        if (rawValue !== undefined && rawValue !== null &&
          !(typeof rawValue === 'string' && rawValue.trim().length === 0)) {
          const value = this.numberValue(rawValue)
          if (value > 0 && Number.isFinite(value)) {
            return Math.floor(value)
          }
        }
      }
    }
    return 0
  }

  private booleanValue(value: Object | undefined): boolean {
    return value === true || value === 'true'
  }

  private booleanFlag(value: Object | undefined): boolean {
    return value === true || value === 1 || value === 'true' || value === '1'
  }

  private isDirectory(raw: JsonObject): boolean {
    const fileType = this.stringValue(raw['file_type']).toLowerCase()
    if (this.numberValue(raw['file_type']) === 1 || fileType === 'dir' || fileType === 'directory' ||
      fileType === 'folder') {
      return true
    }
    return this.booleanFlag(raw['is_dir']) || this.booleanFlag(raw['is_directory']) ||
      this.booleanFlag(raw['is_folder']) || this.booleanFlag(raw['directory'])
  }

  private directoryChildCount(raw: JsonObject): number {
    const keys = [
      'child_count', 'children_count', 'file_count', 'folder_count',
      'items_count', 'total_count'
    ]
    for (const key of keys) {
      const rawValue = raw[key]
      if (rawValue === undefined || rawValue === null ||
        (typeof rawValue === 'string' && rawValue.trim().length === 0)) {
        continue
      }
      const value = this.numberValue(rawValue)
      if (value >= 0 && Number.isFinite(value)) {
        return Math.floor(value)
      }
    }
    return -1
  }

  private firstCount(raw: JsonObject, keys: string[]): number {
    for (const key of keys) {
      const rawValue = raw[key]
      if (rawValue === undefined || rawValue === null ||
        (typeof rawValue === 'string' && rawValue.trim().length === 0)) {
        continue
      }
      const value = this.numberValue(rawValue)
      if (value >= 0 && Number.isFinite(value)) {
        return Math.floor(value)
      }
    }
    return -1
  }

  private sortEntries(entries: FileEntry[]): void {
    entries.sort((left: FileEntry, right: FileEntry): number => {
      if (left.isDirectory !== right.isDirectory) {
        return left.isDirectory ? -1 : 1
      }
      return left.name.localeCompare(right.name)
    })
  }

  private firstString(raw: JsonObject, keys: string[]): string {
    for (const key of keys) {
      const value = this.stringValue(raw[key]).trim()
      if (value.length > 0) {
        return value
      }
    }
    return ''
  }

  private remotePreviewUrl(urls: UgreenEndpoints, raw: JsonObject, keys: string[]): string {
    const direct = this.firstRemoteValue(raw, keys)
    if (direct.length === 0) {
      return ''
    }
    return urls.downloadLink(direct)
  }

  private firstRemoteValue(raw: JsonObject, keys: string[]): string {
    for (const key of keys) {
      const direct = this.remoteValue(raw[key])
      if (direct.length > 0) {
        return direct
      }
    }

    const containers = [
      'metadata', 'meta', 'file_info', 'fileInfo', 'media', 'extra', 'preview_info', 'previewInfo'
    ]
    for (const containerName of containers) {
      const container = this.asRecord(raw[containerName])
      for (const key of keys) {
        const nested = this.remoteValue(container[key])
        if (nested.length > 0) {
          return nested
        }
      }
    }
    return ''
  }

  private remoteValue(value: Object | undefined): string {
    if (typeof value === 'string') {
      return value.trim()
    }
    if (value === undefined || value === null || typeof value !== 'object') {
      return ''
    }
    const record = this.asRecord(value)
    return this.firstString(record, [
      'url', 'uri', 'src', 'path', 'value', 'small', 'small_url', 'smallUrl',
      'thumbnail_url', 'thumbnailUrl', 'preview_url', 'previewUrl', 'cover_url', 'coverUrl'
    ])
  }

  private previewPath(entry: FileEntry): string {
    if (entry.coverUrl.length > 0 && this.isAudioFile(entry.name)) {
      return entry.coverUrl
    }
    return entry.thumbnailUrl
  }

  private isAudioFile(name: string): boolean {
    const dot = name.lastIndexOf('.')
    if (dot <= 0 || dot === name.length - 1) {
      return false
    }
    const extension = name.substring(dot + 1).toLowerCase()
    return ['mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg', 'amr'].indexOf(extension) >= 0
  }

  private normalizePath(path: string): string {
    const value = path.trim()
    if (value.length === 0) {
      return ''
    }
    return value.replace(/\/{2,}/g, '/')
  }

  private headerValue(headers: Record<string, string>, target: string): string {
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === target.toLowerCase()) {
        return headers[key]
      }
    }
    return ''
  }

  private joinPath(parent: string, name: string): string {
    if (parent.length === 0 || parent === '/') {
      return '/' + name
    }
    return parent.replace(/\/+$/, '') + '/' + name
  }

  private fileName(path: string): string {
    const normalized = path.replace(/\/+$/, '')
    const separator = normalized.lastIndexOf('/')
    return separator >= 0 ? normalized.substring(separator + 1) : normalized
  }

  private withHeaders(source: Record<string, string>, key: string, value: string): Record<string, string> {
    const result: Record<string, string> = {}
    for (const headerKey of Object.keys(source)) {
      result[headerKey] = source[headerKey]
    }
    result[key] = value
    return result
  }
}

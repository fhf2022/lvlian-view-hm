import { StorageBudget } from '../../download/StorageBudget'
import { NasConnection } from './NasConnection'
import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { UgreenError, UgreenErrorKind } from '../../ugreen/UgreenErrors'
import { HttpResult, JsonObject } from './HttpTypes'
import { RemoteFileVersion } from './RemoteFileVersion'

export interface BinaryDownloadProgress {
  receiveSize: number
  totalSize: number
  etag?: string
  resumeValidator?: string
}

export type BinaryProgressListener = (progress: BinaryDownloadProgress) => void

export interface StreamDownloadResult {
  responseCode: number
  totalSize: number
  receivedSize: number
  resumed: boolean
  etag?: string
  resumeValidator?: string
}

export interface BinaryRangeResult {
  responseCode: number
  start: number
  totalSize: number
  bytes: Uint8Array
  headers: Record<string, string>
}

export class HttpTransport {
  async postUpload(url: string, bytes: ArrayBuffer,
    headers: Record<string, string>): Promise<JsonObject> {
    const attempt = NasConnection.shared().begin(url)
    const request = http.createHttp()
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.POST, header: headers, extraData: bytes,
        expectDataType: http.HttpDataType.STRING, usingCache: false,
        connectTimeout: 6000, readTimeout: 60000
      })
      this.checkResponse(url, attempt, Number(response.responseCode))
      return this.parseJson(this.responseText(response.result))
    } catch (error) {
      throw this.requestFailure(error as Object, url, attempt)
    } finally { request.destroy() }
  }

  async requestJson(url: string, method: http.RequestMethod, body?: JsonObject,
    headers: Record<string, string> = {}, recovery: boolean = false,
    readTimeoutMs: number = 20000): Promise<HttpResult<JsonObject>> {
    const attempt = NasConnection.shared().begin(url, recovery)
    const request = http.createHttp()
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: recovery ? 5000 : 6000,
        readTimeout: recovery ? 8000 : readTimeoutMs,
        usingCache: false
      }
      if (body !== undefined) {
        options.extraData = JSON.stringify(body)
      }
      const response = await request.request(url, options)
      const responseText = this.responseText(response.result)
      this.checkResponse(url, attempt, Number(response.responseCode), recovery)
      const parsed = this.parseJson(responseText)
      const responseHeaders = this.toHeaders(response.header)
      const status = Number(response.responseCode)
      return new HttpResult<JsonObject>(parsed, status, responseHeaders)
    } catch (error) {
      if (error instanceof UgreenError) {
        throw error
      }
      throw this.requestFailure(error as Object, url, attempt)
    } finally {
      request.destroy()
    }
  }

  async requestBinary(url: string, headers: Record<string, string> = {},
    onProgress?: BinaryProgressListener): Promise<Uint8Array> {
    const attempt = NasConnection.shared().begin(url)
    const request = http.createHttp()
    const progressCallback = (progress: http.DataReceiveProgressInfo): void => {
      if (onProgress !== undefined) {
        onProgress({
          receiveSize: progress.receiveSize,
          totalSize: progress.totalSize
        })
      }
    }
    if (onProgress !== undefined) {
      request.on('dataReceiveProgress', progressCallback)
    }
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 6000,
        readTimeout: 120000,
        usingCache: false
      })
      const status = Number(response.responseCode)
      this.checkResponse(url, attempt, status)
      return new Uint8Array(response.result as ArrayBuffer)
    } catch (error) {
      if (error instanceof UgreenError) {
        throw error
      }
      throw this.requestFailure(error as Object, url, attempt)
    } finally {
      if (onProgress !== undefined) {
        request.off('dataReceiveProgress', progressCallback)
      }
      request.destroy()
    }
  }

  /**
   * Fetches one bounded byte range. The video MediaSource loader uses this
   * instead of assembling the whole movie in memory. A non-zero range must be
   * answered with HTTP 206; accepting a 200 response there would duplicate
   * the file at the requested offset and corrupt the sparse .part file.
   */
  async requestBinaryRange(url: string, start: number, length: number,
    headers: Record<string, string> = {}, readTimeoutMs: number = 120000): Promise<BinaryRangeResult> {
    const safeStart = Math.max(0, Math.floor(start))
    const safeLength = Math.max(1, Math.floor(length))
    const attempt = NasConnection.shared().begin(url)
    const request = http.createHttp()
    const requestHeaders: Record<string, string> = {}
    for (const key of Object.keys(headers)) {
      requestHeaders[key] = headers[key]
    }
    requestHeaders['Range'] = 'bytes=' + safeStart.toString() + '-' +
      (safeStart + safeLength - 1).toString()
    let responseCode = 0
    let responseHeaders: Record<string, string> = {}
    let receivedBytes = 0
    const chunks: Uint8Array[] = []
    let dataResolve: (() => void) | null = null
    let dataReject: ((error: Object) => void) | null = null
    let streamFinished = false
    let rangeError: Object | null = null
    const dataFinished = new Promise<void>((resolve, reject) => {
      dataResolve = resolve
      dataReject = reject
    })
    const failStream = (error: Object): void => {
      if (streamFinished) {
        return
      }
      streamFinished = true
      rangeError = error
      if (dataReject !== null) {
        dataReject(error)
        dataReject = null
      }
      try {
        request.destroy()
      } catch (_) {
        // The request may already be at dataEnd.
      }
    }
    const headersCallback = (raw: Object): void => {
      responseHeaders = this.toHeaders(raw)
      const status = this.headerStatus(responseHeaders)
      if ((status === 0 || (status >= 300 && status < 400)) &&
        this.headerValue(responseHeaders, 'location').length > 0) { return }
      if (status > 0 && status < 200) { return }
      if (status >= 200) {
        try { this.checkResponse(url, attempt, status) }
        catch (error) { failStream(error as Object); return }
      }
      const validator = requestHeaders['If-Range'] || ''
      if (validator.length > 0 && !RemoteFileVersion.matches(validator, responseHeaders)) {
        failStream(new UgreenError(UgreenErrorKind.NETWORK, '远端文件已变化，请重新下载', 206))
        return
      }
      const advertisedLength = this.numberHeader(responseHeaders, 'content-length')
      if (advertisedLength > safeLength) {
        failStream(new UgreenError(UgreenErrorKind.NETWORK,
          '服务器返回了超出请求范围的视频数据', 0))
      }
    }
    const dataCallback = (chunk: ArrayBuffer): void => {
      if (streamFinished) {
        return
      }
      const bytes = new Uint8Array(chunk)
      if (receivedBytes + bytes.byteLength > safeLength) {
        failStream(new UgreenError(UgreenErrorKind.NETWORK,
          '服务器返回了超出请求范围的视频数据', responseCode))
        return
      }
      if (bytes.byteLength > 0) {
        chunks.push(bytes)
        receivedBytes += bytes.byteLength
      }
    }
    const endCallback = (): void => {
      if (streamFinished) {
        return
      }
      streamFinished = true
      if (dataResolve !== null) {
        dataResolve()
        dataResolve = null
      }
    }
    dataFinished.catch((): void => {})
    request.on('headersReceive', headersCallback)
    request.on('dataReceive', dataCallback)
    request.on('dataEnd', endCallback)
    try {
      responseCode = await request.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: requestHeaders,
        connectTimeout: 6000,
        readTimeout: readTimeoutMs,
        usingCache: false
      })
      const status = Number(responseCode)
      this.checkResponse(url, attempt, status)
      await dataFinished
      const contentRange = this.headerValue(responseHeaders, 'content-range')
      const responseStart = status === 206 ? this.rangeStart(contentRange) : 0
      if (safeStart > 0 && status !== 206) {
        throw new UgreenError(UgreenErrorKind.NETWORK,
          '服务器不支持视频 Range 播放', status)
      }
      if (status === 206 && responseStart !== safeStart) {
        throw new UgreenError(UgreenErrorKind.NETWORK,
          '服务器返回了错误的视频分段范围', status)
      }
      const bytes = new Uint8Array(receivedBytes)
      let copyOffset = 0
      for (const chunk of chunks) {
        bytes.set(chunk, copyOffset)
        copyOffset += chunk.byteLength
      }
      if (bytes.byteLength <= 0) {
        throw new UgreenError(UgreenErrorKind.NETWORK, '视频分段为空', status)
      }
      const totalFromRange = this.rangeTotal(contentRange)
      const contentLength = this.numberHeader(responseHeaders, 'content-length')
      // A 206 response without the complete Content-Range total is still
      // usable for streaming, but it is not safe to promote as a complete
      // durable file. Returning zero keeps the transfer manager from
      // mistaking the first chunk for the whole movie.
      const totalSize = totalFromRange > 0
        ? totalFromRange : (status === 206 ? 0 :
          (contentLength > 0 ? contentLength : bytes.byteLength))
      return {
        responseCode: status,
        start: responseStart,
        totalSize: totalSize,
        bytes: bytes,
        headers: responseHeaders
      }
    } catch (error) {
      if (rangeError !== null) { throw rangeError as Error }
      if (error instanceof UgreenError) {
        throw error
      }
      throw this.requestFailure(error as Object, url, attempt)
    } finally {
      request.destroy()
      request.off('dataReceive', dataCallback)
      request.off('dataEnd', endCallback)
      request.off('headersReceive', headersCallback)
    }
  }

  /**
   * Streams a binary response directly into a private .part file. The HTTP
   * response itself is never assembled into one large ArrayBuffer, which is
   * important for original images and later video support.
   */
  async requestBinaryToFile(url: string, targetPath: string,
    headers: Record<string, string> = {}, resumeOffset: number = 0,
    expectedTotal: number = 0, onProgress?: BinaryProgressListener,
    shouldContinue?: () => boolean, expectedValidator: string = ''): Promise<StreamDownloadResult> {
    const attempt = NasConnection.shared().begin(url)
    const request = http.createHttp()
    const requestHeaders: Record<string, string> = {}
    for (const key of Object.keys(headers)) {
      requestHeaders[key] = headers[key]
    }
    if (resumeOffset > 0) {
      requestHeaders['Range'] = 'bytes=' + resumeOffset.toString() + '-'
      const validator = RemoteFileVersion.strongEtag(expectedValidator)
      if (validator.length > 0) { requestHeaders['If-Range'] = validator }
    }

    StorageBudget.pin(targetPath)
    let streamError: Object | null = null
    let fileFd: number = -1
    let receivedSize = 0
    let totalSize = expectedTotal
    let responseCode = 0
    let responseHeaders: Record<string, string> = {}
    let responseValidator = ''
    let headerResolve: (() => void) | null = null
    let headerReject: ((error: Object) => void) | null = null
    const headerReady = new Promise<void>((resolve, reject) => {
      headerResolve = resolve
      headerReject = reject
    })
    let dataResolve: (() => void) | null = null
    let dataReject: ((error: Object) => void) | null = null
    const dataFinished = new Promise<void>((resolve, reject) => {
      dataResolve = resolve
      dataReject = reject
    })
    let paused = false
    let requestStarted = false
    // requestInStream delivers data while its promise is still pending. The
    // previous implementation opened the .part file only after awaiting that
    // promise, so the first chunk hit fileFd === -1 and every original-image
    // preload failed. Resolve the file mode from response headers first and
    // open the destination before accepting data.
    let appendMode = false
    const replacementPath = targetPath + '.incoming'
    let activePath = targetPath
    let replacementUsed = false
    let replacementCommitted = false
    let targetOpened = false

    const openStreamFile = (append: boolean, replacement: boolean = false): void => {
      if (fileFd >= 0) {
        return
      }
      appendMode = append
      if (replacement) {
        activePath = replacementPath
        replacementUsed = true
        StorageBudget.pin(replacementPath)
      } else { targetOpened = true }
      const openMode = fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE |
        (append ? fileIo.OpenMode.APPEND : fileIo.OpenMode.TRUNC)
      const file = fileIo.openSync(activePath, openMode)
      fileFd = file.fd
    }

    const headersCallback = (raw: Object): void => {
      try {
        responseHeaders = this.toHeaders(raw)
        const status = this.headerStatus(responseHeaders)
        if (status > 0 && status < 200) { return }
        if ((status === 0 || (status >= 300 && status < 400)) &&
          this.headerValue(responseHeaders, 'location').length > 0) { return }
        // headersReceive precedes dataReceive. Reject a gateway error before
        // opening/TRUNCating an existing partial file or writing its HTML body.
        // Some NEXT runtimes omit status-line from this event although the
        // completed response still supplies its code. Do not require it.
        if (status > 0) { this.checkResponse(url, attempt, status) }
        // For a resumed request, Content-Range is available before the
        // requestInStream promise resolves and tells us whether APPEND is
        // safe. A normal request always starts from zero and is truncated.
        const rangeStart = this.rangeStart(this.headerValue(responseHeaders, 'content-range'))
        if (status === 206 && resumeOffset > 0 && rangeStart !== resumeOffset) {
          throw new UgreenError(UgreenErrorKind.NETWORK, '服务器返回了无效的断点范围', status)
        }
        const append = resumeOffset > 0 && rangeStart === resumeOffset
        if (append && !RemoteFileVersion.matches(expectedValidator, responseHeaders)) {
          throw new UgreenError(UgreenErrorKind.NETWORK, '远端文件已变化，重新下载', 206)
        }
        const rangeTotal = this.rangeTotal(this.headerValue(responseHeaders, 'content-range'))
        if (append && expectedTotal > 0 && rangeTotal !== expectedTotal) {
          throw new UgreenError(UgreenErrorKind.NETWORK, '远端文件大小已变化，重新下载', 206)
        }
        responseValidator = RemoteFileVersion.fromHeaders(responseHeaders)
        // Without a matching range, stream a potential 200 fallback into a
        // separate file. Commit by rename only after its final status is valid;
        // a gateway page cannot truncate the existing resumable prefix.
        openStreamFile(append, resumeOffset > 0 && !append)
        if (headerResolve !== null) {
          headerResolve()
        }
      } catch (error) {
        streamError = error as Object
        paused = true
        if (headerReject !== null) {
          headerReject(error as Object)
        }
        if (dataReject !== null) { dataReject(error as Object) }
        try { request.destroy() } catch (_) {}
      }
    }
    const dataCallback = (chunk: ArrayBuffer): void => {
      try {
        if (paused) { return }
        if (shouldContinue !== undefined && !shouldContinue()) {
          paused = true
          if (dataReject !== null) {
            dataReject(new UgreenError(UgreenErrorKind.NETWORK,
              '自动原图加载已暂停', 499))
            dataReject = null
          }
          request.destroy()
          return
        }
        if (fileFd < 0) {
          throw new UgreenError(UgreenErrorKind.NETWORK, '下载响应尚未准备好', 0)
        }
        StorageBudget.admit(activePath, (appendMode ? resumeOffset : 0) + receivedSize + chunk.byteLength)
        let written = 0
        while (written < chunk.byteLength) {
          const count = fileIo.writeSync(fileFd, chunk.slice(written))
          if (count <= 0) { throw new Error('写入文件失败') }
          written += count
        }
        receivedSize += written
        StorageBudget.sync(activePath)
        if (onProgress !== undefined) {
          onProgress({ receiveSize: (appendMode ? resumeOffset : 0) + receivedSize, totalSize: totalSize,
            etag: replacementUsed ? undefined : this.headerValue(responseHeaders, 'etag'),
            resumeValidator: replacementUsed ? undefined : responseValidator })
        }
      } catch (error) {
        streamError = error as Object
        paused = true
        if (dataReject !== null) { dataReject(error as Object) }
        request.destroy()
      }
    }
    const endCallback = (): void => {
      if (dataResolve !== null) {
        dataResolve()
      }
    }

    headerReady.catch((): void => {})
    dataFinished.catch((): void => {})
    request.on('headersReceive', headersCallback)
    request.on('dataReceive', dataCallback)
    request.on('dataEnd', endCallback)
    try {
      // Open only after accepted response headers; a failed request must leave
      // the existing .part untouched. Data is still written directly to disk.
      requestStarted = true
      responseCode = await request.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: requestHeaders,
        connectTimeout: 6000,
        readTimeout: 120000,
        usingCache: false
      })
      this.checkResponse(url, attempt, responseCode)
      await headerReady

      const append = this.shouldAppendResponse(responseCode, resumeOffset, responseHeaders)
      const contentRange = this.headerValue(responseHeaders, 'content-range')
      if (responseCode === 206 && resumeOffset > 0 && !append) {
        throw new UgreenError(UgreenErrorKind.NETWORK, '服务器返回了无效的断点范围', responseCode)
      }
      if (append !== appendMode) {
        throw new UgreenError(UgreenErrorKind.NETWORK, '下载响应范围与文件模式不一致', responseCode)
      }
      const contentLength = this.numberHeader(responseHeaders, 'content-length')
      const rangeTotal = this.rangeTotal(contentRange)
      if (rangeTotal > 0) {
        totalSize = rangeTotal
      } else if (contentLength > 0) {
        totalSize = append ? resumeOffset + contentLength : contentLength
      }
      if (onProgress !== undefined) {
        onProgress({ receiveSize: append ? resumeOffset : 0, totalSize: totalSize })
      }
      await dataFinished
      const finalReceived = (append ? resumeOffset : 0) + receivedSize
      if (replacementUsed) {
        fileIo.closeSync(fileFd)
        fileFd = -1
        fileIo.renameSync(replacementPath, targetPath)
        replacementCommitted = true
        StorageBudget.sync(targetPath)
      }
      if (onProgress !== undefined) {
        onProgress({ receiveSize: finalReceived, totalSize: totalSize })
      }
      return {
        responseCode: responseCode,
        totalSize: totalSize,
        receivedSize: finalReceived,
        resumed: append,
        etag: this.headerValue(responseHeaders, 'etag'),
        resumeValidator: responseValidator
      }
    } catch (error) {
      if (streamError !== null) { throw streamError as Error }
      if (paused && streamError === null) {
        throw new UgreenError(UgreenErrorKind.NETWORK, '下载已暂停', 499)
      }
      if (error instanceof UgreenError) {
        throw error
      }
      if (!requestStarted) { throw error as Error }
      throw this.requestFailure(error as Object, url, attempt)
    } finally {
      if (fileFd >= 0) {
        try {
          fileIo.closeSync(fileFd)
        } catch (_) {
          // The stream may already have closed the descriptor after an error.
        }
      }
      request.off('dataReceive', dataCallback)
      request.off('dataEnd', endCallback)
      request.off('headersReceive', headersCallback)
      request.destroy()
      if (replacementUsed) {
        if (!replacementCommitted) { try { fileIo.unlinkSync(replacementPath) } catch (_) {} }
        StorageBudget.unpin(replacementPath)
      }
      if (targetOpened && resumeOffset <= 0 && responseCode >= 300) {
        // A first request whose event omitted status-line may have delivered
        // an error body. It is never a valid resumable file.
        try { fileIo.unlinkSync(targetPath) } catch (_) {}
      }
      StorageBudget.unpin(targetPath)
    }
  }

  private checkResponse(url: string, attempt: number, status: number, recovery: boolean = false): void {
    if (!recovery || status === 502 || status === 503 || status === 504) {
      NasConnection.shared().response(url, attempt, status)
    }
    if (status >= 200 && status < 300) { return }
    const kind = status === 401 ? UgreenErrorKind.AUTH_EXPIRED :
      (status === 403 ? UgreenErrorKind.PERMISSION_DENIED :
      (status === 404 || status === 410 ? UgreenErrorKind.NOT_FOUND : UgreenErrorKind.NETWORK))
    throw new UgreenError(kind, '请求失败（HTTP ' + status.toString() + '）', status)
  }

  private parseJson(text: string): JsonObject {
    if (text.length === 0) { return {} }
    try { return JSON.parse(text) as JsonObject }
    catch (_) { throw new UgreenError(UgreenErrorKind.API_CHANGED, '服务器返回的数据格式异常') }
  }

  private requestFailure(error: Object, url: string, attempt: number): UgreenError {
    if (error instanceof UgreenError) { return error }
    NasConnection.shared().failed(url, attempt)
    // Do not log signed URLs, tokens or response bodies.
    console.warn('[UgreenHTTP] transport unavailable')
    return new UgreenError(attempt > 0 ? UgreenErrorKind.NAS_UNAVAILABLE : UgreenErrorKind.NETWORK,
      attempt > 0 ? 'NAS 暂时无法连接，已缓存内容仍可浏览' : '网络请求失败，请检查网络连接')
  }

  private responseText(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result
    }
    if (result instanceof ArrayBuffer) {
      const decoder = new util.TextDecoder('utf-8', { ignoreBOM: true })
      return decoder.decodeToString(new Uint8Array(result))
    }
    return JSON.stringify(result)
  }

  private toHeaders(raw: Object): Record<string, string> {
    const result: Record<string, string> = {}
    const source = raw as Record<string, Object>
    for (const key of Object.keys(source)) {
      result[key] = String(source[key])
    }
    return result
  }

  private headerValue(headers: Record<string, string>, name: string): string {
    const lowerName = name.toLowerCase()
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === lowerName) {
        return headers[key]
      }
    }
    return ''
  }

  private headerStatus(headers: Record<string, string>): number {
    const line = this.headerValue(headers, 'status-line')
    const match = /^HTTP\/\S+\s+(\d{3})/i.exec(line)
    return match === null ? 0 : Number(match[1])
  }

  private numberHeader(headers: Record<string, string>, name: string): number {
    const value = Number(this.headerValue(headers, name))
    return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0
  }

  private rangeTotal(contentRange: string): number {
    const slash = contentRange.lastIndexOf('/')
    if (slash < 0) {
      return 0
    }
    const value = Number(contentRange.substring(slash + 1).trim())
    return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0
  }

  private rangeStart(contentRange: string): number {
    const space = contentRange.indexOf(' ')
    const dash = contentRange.indexOf('-')
    if (space < 0 || dash < 0 || dash <= space) {
      return -1
    }
    const value = Number(contentRange.substring(space + 1, dash).trim())
    return Number.isFinite(value) && value >= 0 ? Math.floor(value) : -1
  }

  private shouldAppendResponse(responseCode: number, resumeOffset: number,
    headers: Record<string, string>): boolean {
    if (resumeOffset <= 0 || responseCode !== 206) {
      return false
    }
    return this.rangeStart(this.headerValue(headers, 'content-range')) === resumeOffset
  }
}

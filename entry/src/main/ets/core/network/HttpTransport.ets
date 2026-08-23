import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { UgreenError, UgreenErrorKind } from '../../ugreen/UgreenErrors'
import { HttpResult, JsonObject } from './HttpTypes'

export interface BinaryDownloadProgress {
  receiveSize: number
  totalSize: number
}

export type BinaryProgressListener = (progress: BinaryDownloadProgress) => void

export interface StreamDownloadResult {
  responseCode: number
  totalSize: number
  receivedSize: number
  resumed: boolean
}

export class HttpTransport {
  async requestJson(url: string, method: http.RequestMethod, body?: JsonObject,
    headers: Record<string, string> = {}): Promise<HttpResult<JsonObject>> {
    const request = http.createHttp()
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 30000,
        readTimeout: 60000,
        usingCache: false
      }
      if (body !== undefined) {
        options.extraData = JSON.stringify(body)
      }
      const response = await request.request(url, options)
      const responseText = this.responseText(response.result)
      let parsed: JsonObject = {}
      if (responseText.length > 0) {
        parsed = JSON.parse(responseText) as JsonObject
      }
      const responseHeaders = this.toHeaders(response.header)
      const status = Number(response.responseCode)
      if (status < 200 || status >= 300) {
        throw new UgreenError(UgreenErrorKind.NETWORK, '网络请求失败（HTTP ' + status.toString() + '）', status)
      }
      return new HttpResult<JsonObject>(parsed, status, responseHeaders)
    } catch (error) {
      if (error instanceof UgreenError) {
        throw error
      }
      console.warn('[UgreenHTTP] json request failed: ' + url + ' :: ' + String(error))
      throw new UgreenError(UgreenErrorKind.NETWORK, '网络请求失败，请检查网络连接')
    } finally {
      request.destroy()
    }
  }

  async requestBinary(url: string, headers: Record<string, string> = {},
    onProgress?: BinaryProgressListener): Promise<Uint8Array> {
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
        connectTimeout: 30000,
        readTimeout: 120000,
        usingCache: false
      })
      const status = Number(response.responseCode)
      if (status < 200 || status >= 300) {
        throw new UgreenError(UgreenErrorKind.NETWORK, '文件下载失败（HTTP ' + status.toString() + '）', status)
      }
      return new Uint8Array(response.result as ArrayBuffer)
    } catch (error) {
      if (error instanceof UgreenError) {
        throw error
      }
      console.warn('[UgreenHTTP] binary request failed: ' + url + ' :: ' + String(error))
      throw new UgreenError(UgreenErrorKind.NETWORK, '文件下载失败，请检查网络连接')
    } finally {
      if (onProgress !== undefined) {
        request.off('dataReceiveProgress', progressCallback)
      }
      request.destroy()
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
    shouldContinue?: () => boolean): Promise<StreamDownloadResult> {
    const request = http.createHttp()
    const requestHeaders: Record<string, string> = {}
    for (const key of Object.keys(headers)) {
      requestHeaders[key] = headers[key]
    }
    if (resumeOffset > 0) {
      requestHeaders['Range'] = 'bytes=' + resumeOffset.toString() + '-'
    }

    let fileFd: number = -1
    let receivedSize = 0
    let totalSize = expectedTotal
    let responseCode = 0
    let responseHeaders: Record<string, string> = {}
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
    // requestInStream delivers data while its promise is still pending. The
    // previous implementation opened the .part file only after awaiting that
    // promise, so the first chunk hit fileFd === -1 and every original-image
    // preload failed. Resolve the file mode from response headers first and
    // open the destination before accepting data.
    let appendMode = false

    const openStreamFile = (append: boolean): void => {
      if (fileFd >= 0) {
        return
      }
      appendMode = append
      const openMode = fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE |
        (append ? fileIo.OpenMode.APPEND : fileIo.OpenMode.TRUNC)
      const file = fileIo.openSync(targetPath, openMode)
      fileFd = file.fd
    }

    const headersCallback = (raw: Object): void => {
      try {
        responseHeaders = this.toHeaders(raw)
        // For a resumed request, Content-Range is available before the
        // requestInStream promise resolves and tells us whether APPEND is
        // safe. A normal request always starts from zero and is truncated.
        const rangeStart = this.rangeStart(this.headerValue(responseHeaders, 'content-range'))
        openStreamFile(resumeOffset > 0 && rangeStart === resumeOffset)
        if (headerResolve !== null) {
          headerResolve()
        }
      } catch (error) {
        if (headerReject !== null) {
          headerReject(error as Object)
        }
      }
    }
    const dataCallback = (chunk: ArrayBuffer): void => {
      try {
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
        if (paused) {
          return
        }
        if (fileFd < 0) {
          throw new UgreenError(UgreenErrorKind.NETWORK, '下载响应尚未准备好', 0)
        }
        fileIo.writeSync(fileFd, chunk)
        receivedSize += chunk.byteLength
        if (onProgress !== undefined) {
          onProgress({ receiveSize: (appendMode ? resumeOffset : 0) + receivedSize, totalSize: totalSize })
        }
      } catch (error) {
        if (dataReject !== null) {
          dataReject(error as Object)
        }
      }
    }
    const endCallback = (): void => {
      if (dataResolve !== null) {
        dataResolve()
      }
    }

    request.once('headersReceive', headersCallback)
    request.on('dataReceive', dataCallback)
    request.on('dataEnd', endCallback)
    try {
      // The normal (non-resumed) path can be opened before the request starts,
      // which also covers devices that dispatch the first data callback very
      // aggressively. Resumed responses wait for Content-Range above.
      if (resumeOffset <= 0) {
        openStreamFile(false)
      }
      responseCode = await request.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: requestHeaders,
        connectTimeout: 30000,
        readTimeout: 120000,
        usingCache: false
      })
      await headerReady
      if (responseCode < 200 || responseCode >= 300) {
        throw new UgreenError(UgreenErrorKind.NETWORK,
          '文件下载失败（HTTP ' + responseCode.toString() + '）', responseCode)
      }

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
      if (onProgress !== undefined) {
        onProgress({ receiveSize: finalReceived, totalSize: totalSize })
      }
      return {
        responseCode: responseCode,
        totalSize: totalSize,
        receivedSize: finalReceived,
        resumed: append
      }
    } catch (error) {
      if (error instanceof UgreenError) {
        throw error
      }
      console.warn('[UgreenHTTP] stream request failed: ' + url +
        ' response=' + responseCode.toString() + ' :: ' + String(error))
      throw new UgreenError(UgreenErrorKind.NETWORK, '文件下载失败，请检查网络连接')
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
    }
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

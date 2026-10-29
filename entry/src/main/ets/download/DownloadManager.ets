import { StorageBudget } from './StorageBudget'
import { fileIo } from '@kit.CoreFileKit'
import { DownloadDescriptor } from '../model/FileEntry'
import { BinaryDownloadProgress, BinaryProgressListener, HttpTransport, StreamDownloadResult } from '../core/network/HttpTransport'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'
import { CacheManager } from './CacheManager'
import { RemoteFileVersion } from '../core/network/RemoteFileVersion'
import { DownloadCancellation } from '../core/network/DownloadCancellation'

interface CacheResumeInfo {
  validator: string
  size: number
  checksum: string
}

export class DownloadManager {
  private transport: HttpTransport

  constructor(transport: HttpTransport) {
    this.transport = transport
  }

  async download(descriptor: DownloadDescriptor, directory: string, maxBytes: number,
    cacheKey: string = '', onProgress?: BinaryProgressListener,
    shouldContinue?: () => boolean, cancellation?: DownloadCancellation): Promise<string> {
    const target = CacheManager.cachePath(directory, descriptor.fileName, cacheKey)
    StorageBudget.pin(target)
    const part = this.partPath(target, descriptor.etag)
    StorageBudget.pin(part)
    StorageBudget.pin(part + '.resume.json')
    try {
      return await this.downloadPinned(descriptor, directory, maxBytes, cacheKey, onProgress, shouldContinue, cancellation)
    } finally {
      StorageBudget.unpin(part)
      StorageBudget.unpin(part + '.resume.json')
      StorageBudget.unpin(target)
    }
  }

  private async downloadPinned(descriptor: DownloadDescriptor, directory: string, maxBytes: number,
    cacheKey: string, onProgress?: BinaryProgressListener,
    shouldContinue?: () => boolean, cancellation?: DownloadCancellation): Promise<string> {
    if (shouldContinue !== undefined && !shouldContinue()) {
      throw new UgreenError(UgreenErrorKind.NETWORK, '下载已取消', 499)
    }
    const targetPath = CacheManager.cachePath(directory, descriptor.fileName, cacheKey)
    if (CacheManager.exists(targetPath)) {
      return targetPath
    }
    const partPath = this.partPath(targetPath, descriptor.etag)
    const saved = this.readResumeInfo(partPath)
    let validator = saved?.validator || RemoteFileVersion.strongEtag(descriptor.etag)
    let resumeOffset = this.fileSize(partPath)
    const versionChanged = saved !== null &&
      RemoteFileVersion.changed(saved.size, /^[A-Za-z]{3}, /.test(saved.validator) ? '' : saved.validator,
        saved.checksum, descriptor.size, descriptor.etag, descriptor.checksum)
    if ((descriptor.size > 0 && resumeOffset > descriptor.size) ||
      (resumeOffset > 0 && (validator.length === 0 || versionChanged))) {
      this.removeFile(partPath)
      resumeOffset = 0
      validator = RemoteFileVersion.strongEtag(descriptor.etag)
    }
    const total = descriptor.size > 0 ? descriptor.size : (saved?.size ?? 0)
    let recorded = ''
    const remember = (progress: BinaryDownloadProgress): void => {
      const next = progress.resumeValidator
      if (next === undefined || next.length === 0) { return }
      const info: CacheResumeInfo = { validator: next, size: progress.totalSize > 0 ? progress.totalSize : total,
        checksum: descriptor.checksum }
      const text = JSON.stringify(info)
      if (text !== recorded) {
        this.writeResumeInfo(partPath, text)
        recorded = text
      }
    }
    const progressListener = (progress: BinaryDownloadProgress): void => {
      remember(progress)
      onProgress?.(progress)
    }
    if (descriptor.size > 0 && resumeOffset === descriptor.size) {
      fileIo.renameSync(partPath, targetPath)
      this.removeResumeInfo(partPath)
      await CacheManager.enforceLimit(directory, maxBytes)
      if (!CacheManager.exists(targetPath)) {
        throw new Error('缓存空间不足，文件未能保留')
      }
      return targetPath
    }

    const incomingBytes = descriptor.size > 0
      ? Math.max(0, descriptor.size - resumeOffset) : 0
    await CacheManager.prepareForIncoming(directory, maxBytes, incomingBytes, targetPath, [partPath])
    try {
      const result = await this.downloadToPart(descriptor, partPath, resumeOffset, progressListener,
        shouldContinue, cancellation, validator, total)
      remember({ receiveSize: result.receivedSize, totalSize: result.totalSize,
        resumeValidator: result.resumeValidator })
      if (shouldContinue !== undefined && !shouldContinue()) {
        throw new UgreenError(UgreenErrorKind.NETWORK, '下载已取消', 499)
      }
      const finalSize = this.fileSize(partPath)
      const expectedSize = descriptor.size > 0 ? descriptor.size : result.totalSize
      if (expectedSize > 0 && finalSize !== expectedSize) {
        throw new Error('文件下载不完整')
      }
      fileIo.renameSync(partPath, targetPath)
      this.removeResumeInfo(partPath)
      await CacheManager.enforceLimit(directory, maxBytes)
      if (!CacheManager.exists(targetPath)) {
        throw new Error('缓存空间不足，文件未能保留')
      }
      return targetPath
    } catch (error) {
      // Some NAS gateways ignore or reject Range. Retry once from zero so a
      // stale .part file cannot be appended to a full response.
      if (resumeOffset > 0 && this.shouldRestartWithoutRange(error)) {
        this.removeFile(partPath)
        recorded = ''
        const retry = await this.downloadToPart(descriptor, partPath, 0, progressListener, shouldContinue, cancellation)
        remember({ receiveSize: retry.receivedSize, totalSize: retry.totalSize,
          resumeValidator: retry.resumeValidator })
        if (shouldContinue !== undefined && !shouldContinue()) {
          throw new UgreenError(UgreenErrorKind.NETWORK, '下载已取消', 499)
        }
        const finalSize = this.fileSize(partPath)
        const expectedSize = descriptor.size > 0 ? descriptor.size : retry.totalSize
        if (expectedSize > 0 && finalSize !== expectedSize) {
          throw new Error('文件下载不完整')
        }
        fileIo.renameSync(partPath, targetPath)
        this.removeResumeInfo(partPath)
        await CacheManager.enforceLimit(directory, maxBytes)
        if (!CacheManager.exists(targetPath)) {
          throw new Error('缓存空间不足，文件未能保留')
        }
        return targetPath
      }
      if (error instanceof UgreenError) {
        throw error
      }
      throw new Error('文件下载失败')
    }
  }

  private shouldRestartWithoutRange(error: Object): boolean {
    if (!(error instanceof UgreenError)) {
      return false
    }
    return error.status === 206 || error.status === 416
  }

  private async downloadToPart(descriptor: DownloadDescriptor, partPath: string,
    resumeOffset: number, onProgress?: BinaryProgressListener,
    shouldContinue?: () => boolean, cancellation?: DownloadCancellation,
    validator: string = descriptor.etag, total: number = descriptor.size): Promise<StreamDownloadResult> {
    return await this.transport.requestBinaryToFile(descriptor.url, partPath, descriptor.headers,
      resumeOffset, total, onProgress, shouldContinue, validator, cancellation)
  }

  private readResumeInfo(part: string): CacheResumeInfo | null {
    try {
      const path = part + '.resume.json'
      if (fileIo.statSync(path).size > 2048) { return null }
      const info = JSON.parse(fileIo.readTextSync(path)) as CacheResumeInfo
      if (typeof info.validator !== 'string' || info.validator.length === 0 || info.validator.length > 256 ||
        RemoteFileVersion.strongEtag(info.validator) !== info.validator ||
        !Number.isSafeInteger(info.size) || info.size < 0 || typeof info.checksum !== 'string') { return null }
      return info
    } catch (_) { return null }
  }

  // A tiny record beside an incomplete file, written only when response
  // version/size changes. No URL, token, progress timer or task database.
  private writeResumeInfo(part: string, text: string): void {
    let fd = -1
    try {
      StorageBudget.admit(part + '.resume.json', text.length)
      fd = fileIo.openSync(part + '.resume.json', fileIo.OpenMode.WRITE_ONLY |
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd
      fileIo.writeSync(fd, text)
      StorageBudget.sync(part + '.resume.json')
    } catch (_) {
      console.warn('[UgreenCache] resume metadata unavailable; a later request may restart')
    } finally {
      if (fd >= 0) { try { fileIo.closeSync(fd) } catch (_) {} }
    }
  }

  private removeResumeInfo(part: string): void {
    try { fileIo.unlinkSync(part + '.resume.json') } catch (_) {}
  }

  private partPath(target: string, etag: string): string {
    const validator = RemoteFileVersion.strongEtag(etag)
    return target + (validator.length > 0 ? '.' + CacheManager.hash(validator) : '') + '.part'
  }

  private fileSize(path: string): number {
    try {
      return fileIo.statSync(path).size
    } catch (_) {
      return 0
    }
  }

  private removeFile(path: string): void {
    this.removeResumeInfo(path)
    try {
      fileIo.unlinkSync(path)
    } catch (_) {
      // A system cache cleanup may have removed the partial file already.
    }
  }
}

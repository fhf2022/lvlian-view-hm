import { StorageBudget } from './StorageBudget'
import { fileIo } from '@kit.CoreFileKit'
import { DownloadDescriptor } from '../model/FileEntry'
import { BinaryProgressListener, HttpTransport, StreamDownloadResult } from '../core/network/HttpTransport'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'
import { CacheManager } from './CacheManager'
import { RemoteFileVersion } from '../core/network/RemoteFileVersion'
import { DownloadCancellation } from '../core/network/DownloadCancellation'

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
    try {
      return await this.downloadPinned(descriptor, directory, maxBytes, cacheKey, onProgress, shouldContinue, cancellation)
    } finally {
      StorageBudget.unpin(part)
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
    let resumeOffset = this.fileSize(partPath)
    if ((descriptor.size > 0 && resumeOffset > descriptor.size) ||
      (resumeOffset > 0 && RemoteFileVersion.strongEtag(descriptor.etag).length === 0)) {
      this.removeFile(partPath)
      resumeOffset = 0
    }
    if (descriptor.size > 0 && resumeOffset === descriptor.size) {
      fileIo.renameSync(partPath, targetPath)
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
      const result = await this.downloadToPart(descriptor, partPath, resumeOffset, onProgress,
        shouldContinue, cancellation)
      if (shouldContinue !== undefined && !shouldContinue()) {
        throw new UgreenError(UgreenErrorKind.NETWORK, '下载已取消', 499)
      }
      const finalSize = this.fileSize(partPath)
      const expectedSize = descriptor.size > 0 ? descriptor.size : result.totalSize
      if (expectedSize > 0 && finalSize !== expectedSize) {
        throw new Error('文件下载不完整')
      }
      fileIo.renameSync(partPath, targetPath)
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
        const retry = await this.downloadToPart(descriptor, partPath, 0, onProgress, shouldContinue, cancellation)
        if (shouldContinue !== undefined && !shouldContinue()) {
          throw new UgreenError(UgreenErrorKind.NETWORK, '下载已取消', 499)
        }
        const finalSize = this.fileSize(partPath)
        const expectedSize = descriptor.size > 0 ? descriptor.size : retry.totalSize
        if (expectedSize > 0 && finalSize !== expectedSize) {
          throw new Error('文件下载不完整')
        }
        fileIo.renameSync(partPath, targetPath)
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
    shouldContinue?: () => boolean, cancellation?: DownloadCancellation): Promise<StreamDownloadResult> {
    return await this.transport.requestBinaryToFile(descriptor.url, partPath, descriptor.headers,
      resumeOffset, descriptor.size, onProgress, shouldContinue, descriptor.etag, cancellation)
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
    try {
      fileIo.unlinkSync(path)
    } catch (_) {
      // A system cache cleanup may have removed the partial file already.
    }
  }
}

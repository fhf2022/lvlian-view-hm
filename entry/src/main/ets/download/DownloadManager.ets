import { fileIo } from '@kit.CoreFileKit'
import { DownloadDescriptor } from '../model/FileEntry'
import { BinaryProgressListener, HttpTransport, StreamDownloadResult } from '../core/network/HttpTransport'
import { UgreenError } from '../ugreen/UgreenErrors'
import { CacheManager } from './CacheManager'

export class DownloadManager {
  private transport: HttpTransport

  constructor(transport: HttpTransport) {
    this.transport = transport
  }

  async download(descriptor: DownloadDescriptor, directory: string, maxBytes: number,
    cacheKey: string = '', onProgress?: BinaryProgressListener,
    shouldContinue?: () => boolean): Promise<string> {
    const targetPath = CacheManager.cachePath(directory, descriptor.fileName, cacheKey)
    if (CacheManager.exists(targetPath)) {
      return targetPath
    }
    const partPath = targetPath + '.part'
    let resumeOffset = this.fileSize(partPath)
    if (descriptor.size > 0 && resumeOffset > descriptor.size) {
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
        shouldContinue)
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
        const retry = await this.downloadToPart(descriptor, partPath, 0, onProgress, shouldContinue)
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
    shouldContinue?: () => boolean): Promise<StreamDownloadResult> {
    return await this.transport.requestBinaryToFile(descriptor.url, partPath, descriptor.headers,
      resumeOffset, descriptor.size, onProgress, shouldContinue)
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

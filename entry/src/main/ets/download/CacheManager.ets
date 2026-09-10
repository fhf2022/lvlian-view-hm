import { StorageBudget } from './StorageBudget'
import { fileIo } from '@kit.CoreFileKit'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'

interface CachedFile {
  path: string
  size: number
  modifiedTime: number
}

/**
 * Manages files downloaded to the application's private cache directory.
 * The limit is an app-level soft limit; HarmonyOS may also clear cacheDir
 * automatically when the device needs storage space.
 */
export class CacheManager {
  static readonly DEFAULT_LIMIT_BYTES: number = 1024 * 1024 * 1024
  static readonly LIMIT_100_MB: number = 100 * 1024 * 1024
  static readonly LIMIT_500_MB: number = 500 * 1024 * 1024
  static readonly LIMIT_1_GB: number = 1024 * 1024 * 1024
  static readonly LIMIT_2_GB: number = 2 * 1024 * 1024 * 1024
  static readonly LIMIT_5_GB: number = 5 * 1024 * 1024 * 1024
  private static writeQueue: Promise<void> = Promise.resolve()

  static async save(bytes: Uint8Array, directory: string, fileName: string, maxBytes: number,
    cacheKey: string = ''): Promise<string> {
    const targetPath = CacheManager.cachePath(directory, fileName, cacheKey)
    const operation = CacheManager.writeQueue.then(async (): Promise<void> => {
      await CacheManager.writeBytes(bytes, directory, targetPath, maxBytes)
    })
    CacheManager.writeQueue = operation.catch((): void => {})
    await operation
    return targetPath
  }

  static cachePath(directory: string, fileName: string, cacheKey: string = ''): string {
    const safeName = CacheManager.safeFileName(fileName)
    const prefix = cacheKey.length > 0 ? CacheManager.hash(cacheKey) + '-' : ''
    return CacheManager.joinPath(directory, prefix + safeName)
  }

  static findExisting(directory: string, fileName: string, cacheKey: string = ''): string {
    const keyedPath = CacheManager.cachePath(directory, fileName, cacheKey)
    if (CacheManager.exists(keyedPath)) {
      StorageBudget.touch(keyedPath)
      return keyedPath
    }
    // A keyed cache lookup must never fall back to an unscoped legacy file.
    // Legacy names were based only on the remote path and can be stale or
    // belong to another account after the account-scoped cache migration.
    if (cacheKey.length > 0) {
      return ''
    }
    const legacyPath = CacheManager.cachePath(directory, fileName)
    if (CacheManager.exists(legacyPath)) { StorageBudget.touch(legacyPath); return legacyPath }
    return ''
  }

  static async prepareForIncoming(directory: string, maxBytes: number, incomingBytes: number,
    targetPath: string, protectedPaths: string[] = []): Promise<void> {
    await CacheManager.makeRoom(directory, maxBytes, incomingBytes, targetPath, protectedPaths)
  }

  static exists(path: string): boolean {
    try {
      return fileIo.statSync(path).isFile()
    } catch (_) {
      return false
    }
  }

  private static async writeBytes(bytes: Uint8Array, directory: string, targetPath: string,
    maxBytes: number): Promise<void> {
    await CacheManager.makeRoom(directory, maxBytes, bytes.byteLength, targetPath)
    const file = fileIo.openSync(targetPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    try {
      StorageBudget.admit(targetPath, bytes.byteLength)
      let written = 0
      while (written < bytes.byteLength) {
        const count = fileIo.writeSync(file.fd, bytes.slice(written).buffer as ArrayBuffer)
        if (count <= 0) { throw new Error('缓存写入失败') }
        written += count
      }
      StorageBudget.sync(targetPath)
    } catch (error) {
      try { fileIo.unlinkSync(targetPath) } catch (_) {}
      throw error as Error
    } finally {
      fileIo.closeSync(file.fd)
      StorageBudget.sync(targetPath)
    }
  }

  static async usage(directory: string): Promise<number> {
    let total = 0
    for (const item of CacheManager.listFiles(directory)) {
      total += item.size
    }
    return total
  }

  static async clear(directory: string): Promise<number> {
    let removedBytes = 0
    const operation = CacheManager.writeQueue.then(async (): Promise<void> => {
      for (const item of CacheManager.listFiles(directory)) {
        try {
          fileIo.unlinkSync(item.path)
          StorageBudget.sync(item.path)
          removedBytes += item.size
        } catch (_) {
          // A system cache cleanup may remove a file while we are clearing it.
        }
      }
    })
    CacheManager.writeQueue = operation.catch((): void => {})
    await operation
    return removedBytes
  }

  static async clearLegacyPreviews(directory: string): Promise<number> {
    let removedBytes = 0
    const operation = CacheManager.writeQueue.then(async (): Promise<void> => {
      for (const item of CacheManager.listFiles(directory)) {
        const lowerPath = item.path.toLowerCase()
        const isLegacyPreview = lowerPath.endsWith('.thumbnail') ||
          lowerPath.endsWith('.image.preview.jpg') || lowerPath.endsWith('.image.preview.png') ||
          lowerPath.endsWith('.video.preview.jpg') || lowerPath.endsWith('.audio.preview.jpg')
        if (!isLegacyPreview) {
          continue
        }
        try {
          fileIo.unlinkSync(item.path)
          StorageBudget.sync(item.path)
          removedBytes += item.size
        } catch (_) {
          // Legacy thumbnails are disposable and can be regenerated.
        }
      }
    })
    CacheManager.writeQueue = operation.catch((): void => {})
    await operation
    return removedBytes
  }

  static async remove(path: string): Promise<void> {
    const operation = CacheManager.writeQueue.then((): void => {
      try {
        fileIo.unlinkSync(path)
        StorageBudget.sync(path)
      } catch (_) {
        // Cache entries are disposable and may already have been evicted.
      }
    })
    CacheManager.writeQueue = operation.catch((): void => {})
    await operation
  }

  static async enforceLimit(directory: string, maxBytes: number): Promise<void> {
    const operation = CacheManager.writeQueue.then(async (): Promise<void> => {
      await CacheManager.makeRoom(directory, maxBytes, 0, '')
    })
    CacheManager.writeQueue = operation.catch((): void => {})
    await operation
  }

  private static async makeRoom(directory: string, maxBytes: number, incomingBytes: number,
    targetPath: string, protectedPaths: string[] = []): Promise<void> {
    if (StorageBudget.isTemporary(directory + '/probe')) {
      StorageBudget.scan()
      const protectedFiles = protectedPaths.concat([targetPath])
      protectedFiles.forEach((path: string): void => StorageBudget.pin(path))
      try { StorageBudget.admit(directory + '/__incoming__', incomingBytes) } finally {
        protectedFiles.forEach((path: string): void => StorageBudget.unpin(path))
      }
      return
    }
    if (directory.endsWith('/ugreen-thumbnail-cache')) {
      maxBytes = Math.min(maxBytes, StorageBudget.thumbnailAllowance())
    }
    if (maxBytes <= 0) {
      return
    }
    if (incomingBytes > maxBytes) {
      throw new UgreenError(UgreenErrorKind.UNKNOWN, '文件大于当前缓存上限，请先提高缓存上限')
    }
    const items = CacheManager.listFiles(directory)
    const candidates: CachedFile[] = []
    let total = 0
    for (const item of items) {
      const isTarget = targetPath.length > 0 && item.path === targetPath
      const isProtected = isTarget || protectedPaths.indexOf(item.path) >= 0
      if (!isTarget) {
        total += item.size
      }
      if (isProtected) {
        continue
      }
      candidates.push(item)
    }
    candidates.sort((left: CachedFile, right: CachedFile): number => left.modifiedTime - right.modifiedTime)
    let projected = total + incomingBytes
    for (const item of candidates) {
      if (projected <= maxBytes) {
        break
      }
      try {
        fileIo.unlinkSync(item.path)
          StorageBudget.sync(item.path)
        projected -= item.size
      } catch (_) {
        // Keep going so another old cache file can still be evicted.
      }
    }
    if (projected > maxBytes) {
      throw new UgreenError(UgreenErrorKind.UNKNOWN, '缓存空间不足，请先清理缓存或提高缓存上限')
    }
  }

  private static listFiles(directory: string): CachedFile[] {
    const result: CachedFile[] = []
    let names: string[] = []
    try {
      names = fileIo.listFileSync(directory)
    } catch (_) {
      return result
    }
    for (const name of names) {
      const path = CacheManager.joinListedPath(directory, name)
      try {
        const stat = fileIo.statSync(path)
        if (stat.isFile()) { result.push({ path: path, size: stat.size, modifiedTime: stat.mtime }) }
      } catch (_) {
        // Ignore entries that disappear between listing and stat.
      }
    }
    return result
  }

  private static joinPath(directory: string, name: string): string {
    return directory.replace(/\/+$/, '') + '/' + name
  }

  private static joinListedPath(directory: string, name: string): string {
    return name.startsWith('/') ? directory.replace(/\/+$/, '') + name : CacheManager.joinPath(directory, name)
  }

  private static safeFileName(name: string): string {
    const trimmed = name.trim()
    if (trimmed.length === 0) {
      return 'ugreen-download-' + Date.now().toString()
    }
    return trimmed.replace(/[\\/:*?"<>|]/g, '_')
  }

  static hash(value: string): string {
    let result = 7
    for (let index = 0; index < value.length; index++) {
      result = (result * 31 + value.charCodeAt(index)) % 2147483647
    }
    return result.toString(16)
  }
}

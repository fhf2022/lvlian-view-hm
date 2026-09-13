import { fileIo } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { media } from '@kit.MediaKit'
import { CacheManager } from '../download/CacheManager'
import { FileEntry } from '../model/FileEntry'
import { ViewerBitmapRecord, ViewerBitmapStore } from './ViewerBitmapStore'

type PreviewKind = 'image' | 'video' | 'audio' | ''

/**
 * Produces the small local previews used by the file list.
 *
 * Server-provided thumbnails are handled by UgreenRemoteRepository. This
 * class only creates a fallback preview from an original file that is already
 * present in the app cache.
 */
export class MediaPreviewManager {
  cachedImagePreview(entry: FileEntry, cacheDirectory: string): string {
    if (this.kind(entry) !== 'image' || cacheDirectory.length === 0) {
      return ''
    }
    return CacheManager.findExistingFast(cacheDirectory, this.imagePreviewFileName(entry),
      this.imagePreviewCacheKey(entry))
  }

  async fromLocal(entry: FileEntry, localPath: string,
    cacheDirectory: string, cacheLimitBytes: number): Promise<string> {
    const kind = this.kind(entry)
    if (kind.length === 0 || localPath.length === 0) {
      return ''
    }
    if (kind === 'image') {
      return await this.createImagePreview(entry, localPath, cacheDirectory, cacheLimitBytes)
    }
    return await this.extractAndCache(entry, kind, cacheDirectory, cacheLimitBytes,
      localPath, '', {})
  }

  /**
   * The file-list fallback must never hand the full original image to Image.
   * ImageSource.sampleSize keeps both axes proportional while bounding the
   * decoded PixelMap to the list profile budget.
   */
  private async createImagePreview(entry: FileEntry, localPath: string,
    cacheDirectory: string, cacheLimitBytes: number): Promise<string> {
    const preservesAlpha = this.shouldPreserveAlpha(entry.name)
    const fileName = this.imagePreviewFileName(entry)
    const cacheKey = this.imagePreviewCacheKey(entry)
    const existingPath = CacheManager.findExisting(cacheDirectory, fileName, cacheKey)
    if (existingPath.length > 0) {
      return existingPath
    }

    const bitmapStore = new ViewerBitmapStore()
    let bitmapRecord: ViewerBitmapRecord | null = null
    let packer: image.ImagePacker | null = null
    try {
      // Generate a canonical EXIF-normalized derivative. Persisted user
      // rotation remains outside the disk bytes and is baked only when this
      // derivative is decoded for a concrete visual state.
      bitmapRecord = await bitmapStore.decode(localPath, 'list', 0)
      if (bitmapRecord === null) {
        return ''
      }
      packer = image.createImagePacker()
      const encoded = await packer.packToData(bitmapRecord.pixelMap, {
        format: preservesAlpha ? 'image/png' : 'image/jpeg',
        quality: 78
      })
      return await CacheManager.save(new Uint8Array(encoded), cacheDirectory,
        fileName, cacheLimitBytes, cacheKey)
    } catch (error) {
      console.warn('[UgreenPreview] local image fallback failed: ' + entry.path + ': ' +
        JSON.stringify(error))
      return ''
    } finally {
      if (packer !== null) {
        try {
          await packer.release()
        } catch (_) {
          // The preview is disposable; release failures must not break browse.
        }
      }
      await bitmapStore.release(bitmapRecord)
    }
  }

  private async extractAndCache(entry: FileEntry, kind: PreviewKind,
    cacheDirectory: string, cacheLimitBytes: number, localPath: string, remoteUrl: string,
    headers: Record<string, string>): Promise<string> {
    const cacheKey = entry.path + ':media-preview:' + kind
    const fileName = entry.name + '.' + kind + '.preview.jpg'
    const existingPath = CacheManager.findExisting(cacheDirectory, fileName, cacheKey)
    if (existingPath.length > 0) {
      return existingPath
    }

    let extractor: media.AVMetadataExtractor | null = null
    let pixelMap: image.PixelMap | null = null
    let sourceFd: number = -1
    try {
      extractor = await media.createAVMetadataExtractor()
      if (remoteUrl.length > 0) {
        extractor.setUrlSource(remoteUrl, headers)
      } else {
        const sourceFile = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY)
        sourceFd = sourceFile.fd
        extractor.fdSrc = {
          fd: sourceFd,
          offset: 0,
          length: fileIo.statSync(localPath).size
        }
      }

      if (kind === 'audio') {
        pixelMap = await extractor.fetchAlbumCover()
      } else {
        pixelMap = await extractor.fetchFrameByTime(0,
          media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
          { width: 180, height: 180 })
      }
      if (pixelMap === null) {
        return ''
      }
      const packer = image.createImagePacker()
      try {
        const encoded = await packer.packToData(pixelMap, {
          format: 'image/jpeg',
          quality: 78
        })
        const savedPath = await CacheManager.save(new Uint8Array(encoded), cacheDirectory,
          fileName, cacheLimitBytes, cacheKey)
        return savedPath
      } finally {
        await packer.release()
      }
    } finally {
      if (pixelMap !== null) {
        try {
          await pixelMap.release()
        } catch (_) {
          // A failed decode can return an already-released PixelMap.
        }
      }
      if (extractor !== null) {
        try {
          await extractor.release()
        } catch (_) {
          // Keep list rendering resilient when a media decoder rejects a file.
        }
      }
      if (sourceFd >= 0) {
        fileIo.closeSync(sourceFd)
      }
    }
  }

  private kind(entry: FileEntry): PreviewKind {
    const extension = this.extension(entry.name)
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff'].indexOf(extension) >= 0) {
      return 'image'
    }
    if (['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'ts'].indexOf(extension) >= 0) {
      return 'video'
    }
    if (['mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg', 'amr'].indexOf(extension) >= 0) {
      return 'audio'
    }
    return ''
  }

  private extension(name: string): string {
    const dot = name.lastIndexOf('.')
    if (dot <= 0 || dot === name.length - 1) {
      return ''
    }
    return name.substring(dot + 1).toLowerCase()
  }

  private shouldPreserveAlpha(name: string): boolean {
    const lower = name.toLowerCase()
    return lower.endsWith('.png') || lower.endsWith('.webp') || lower.endsWith('.gif')
  }

  private imagePreviewFileName(entry: FileEntry): string {
    return entry.name + '.image.preview.' + (this.shouldPreserveAlpha(entry.name) ? 'png' : 'jpg')
  }

  private imagePreviewCacheKey(entry: FileEntry): string {
    return entry.path + ':media-preview:image-v5-imagekit-canonical:' + entry.modifiedTime.toString() + ':' +
      entry.size.toString()
  }
}

import { image } from '@kit.ImageKit'
import { fileIo } from '@kit.CoreFileKit'
import { ThumbnailMetrics, ThumbnailPolicy, ThumbnailProfile } from './ThumbnailPolicy'
import { CacheManager } from '../download/CacheManager'

export interface PreparedThumbnail {
  path: string
  metrics: ThumbnailMetrics
}

/**
 * Validates the physical dimensions of a downloaded preview and, when needed,
 * downsamples it during decode before it can reach an Image component.
 */
export class ThumbnailNormalizer {
  async prepare(bytes: Uint8Array, entryPath: string, sourceName: string,
    cacheDirectory: string, cacheLimitBytes: number, profile: ThumbnailProfile,
    cacheKey: string): Promise<PreparedThumbnail | null> {
    const startedAt = Date.now()
    let source: image.ImageSource | null = null
    let pixelMap: image.PixelMap | null = null
    let packer: image.ImagePacker | null = null
    let sourceFd: number = -1
    let outputPath = ''
    try {
      // ImageSource(ArrayBuffer) rejects otherwise valid JPEG/WebP responses
      // on some HarmonyOS builds. Persist the NAS thumbnail first and decode
      // it through a file descriptor, which is the stable Image Kit path used
      // by the local-image preview flow as well.
      outputPath = await CacheManager.save(bytes, cacheDirectory,
        sourceName, cacheLimitBytes, cacheKey)

      // The authoritative UGREEN size_type=1 route already returns a bounded
      // list thumbnail (the device sample is 400 x 672, about 1 MiB decoded).
      // ArkUI Image renders these files correctly while ImageSource's metadata
      // decoder rejects this NAS encoding. Keep the server thumbnail as-is;
      // ImageFit.Cover performs visual cropping without changing its geometry.
      if (profile === 'list' && this.hasImageSignature(bytes) &&
        bytes.byteLength <= ThumbnailPolicy.SERVER_THUMBNAIL_MAX_BYTES) {
        const metrics: ThumbnailMetrics = {
          path: entryPath,
          profile: profile,
          sourceBytes: bytes.byteLength,
          sourceWidth: 0,
          sourceHeight: 0,
          outputWidth: 0,
          outputHeight: 0,
          outputPixelBytes: 0,
          elapsedMs: Date.now() - startedAt
        }
        return { path: outputPath, metrics: metrics }
      }

      const sourceFile = fileIo.openSync(outputPath, fileIo.OpenMode.READ_ONLY)
      sourceFd = sourceFile.fd
      source = image.createImageSource(sourceFd)
      const sourceInfo = source.getImageInfoSync()
      const sourceWidth = Math.max(1, sourceInfo.size.width)
      const sourceHeight = Math.max(1, sourceInfo.size.height)
      let outputBytes = bytes
      let outputWidth = sourceWidth
      let outputHeight = sourceHeight
      let outputPixelBytes = ThumbnailPolicy.estimatedPixelBytes(outputWidth, outputHeight)

      if (ThumbnailPolicy.needsDownsample(sourceWidth, sourceHeight, profile)) {
        pixelMap = await source.createPixelMap({
          // sampleSize applies the same scale on both axes. This is
          // intentional: the file-list may crop with ImageFit.Cover, but the
          // bytes themselves must never be stretched or geometrically warped.
          sampleSize: ThumbnailPolicy.sampleSize(sourceWidth, sourceHeight, profile),
          editable: false
        })
        const outputInfo = pixelMap.getImageInfoSync()
        outputWidth = Math.max(1, outputInfo.size.width)
        outputHeight = Math.max(1, outputInfo.size.height)
        outputPixelBytes = pixelMap.getPixelBytesNumber()
        packer = image.createImagePacker()
        const format = this.shouldPreserveAlpha(sourceName) ? 'image/png' : 'image/jpeg'
        const encoded = await packer.packToData(pixelMap, {
          format: format,
          quality: 82
        })
        outputBytes = new Uint8Array(encoded)
      }

      if (outputBytes !== bytes) {
        // Finish all reads before replacing the raw server thumbnail.
        if (source !== null) {
          await source.release()
          source = null
        }
        if (sourceFd >= 0) {
          fileIo.closeSync(sourceFd)
          sourceFd = -1
        }
        outputPath = await CacheManager.save(outputBytes, cacheDirectory,
          sourceName, cacheLimitBytes, cacheKey)
      }
      const metrics: ThumbnailMetrics = {
        path: entryPath,
        profile: profile,
        sourceBytes: bytes.byteLength,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        outputPixelBytes: outputPixelBytes,
        elapsedMs: Date.now() - startedAt
      }
      console.info('[UgreenThumbnail] ' + JSON.stringify(metrics))
      return { path: outputPath, metrics: metrics }
    } catch (error) {
      console.error('[UgreenThumbnail] normalize failed: bytes=' + bytes.byteLength.toString() +
        ', magic=' + this.magic(bytes) + ', source=' + sourceName + ', profile=' + profile + ': ' +
        JSON.stringify(error))
      // UGREEN's thumbnail service can return JPEG/WebP variants that the
      // synchronous ImageSource metadata decoder rejects even though ArkUI's
      // Image component renders them. Do not turn that compatibility issue
      // into an empty list preview: retain only payloads with a real image
      // signature and let the component's decoder consume the persisted file.
      if (outputPath.length > 0 && this.hasImageSignature(bytes) &&
        (profile !== 'list' || bytes.byteLength <= ThumbnailPolicy.SERVER_THUMBNAIL_MAX_BYTES)) {
        const metrics: ThumbnailMetrics = {
          path: entryPath,
          profile: profile,
          sourceBytes: bytes.byteLength,
          sourceWidth: 0,
          sourceHeight: 0,
          outputWidth: 0,
          outputHeight: 0,
          outputPixelBytes: 0,
          elapsedMs: Date.now() - startedAt
        }
        console.info('[UgreenThumbnail] persisted decoder-compatible fallback: ' + entryPath)
        return { path: outputPath, metrics: metrics }
      }
      if (outputPath.length > 0) {
        await CacheManager.remove(outputPath)
      }
      return null
    } finally {
      if (packer !== null) {
        try {
          await packer.release()
        } catch (_) {
          // The preview is disposable; release failures must not break browse.
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release()
        } catch (_) {
          // The decoder can return an already-released map after an error.
        }
      }
      if (source !== null) {
        try {
          await source.release()
        } catch (_) {
          // Keep a failed preview isolated from the directory page.
        }
      }
      if (sourceFd >= 0) {
        try {
          fileIo.closeSync(sourceFd)
        } catch (_) {
          // The decoder may already have closed the descriptor.
        }
      }
    }
  }

  private shouldPreserveAlpha(name: string): boolean {
    const lower = name.toLowerCase()
    return lower.endsWith('.png') || lower.endsWith('.webp') || lower.endsWith('.gif')
  }

  private magic(bytes: Uint8Array): string {
    const length = Math.min(12, bytes.byteLength)
    let result = ''
    for (let index = 0; index < length; index += 1) {
      if (index > 0) {
        result += ' '
      }
      result += bytes[index].toString(16).padStart(2, '0')
    }
    return result
  }

  private hasImageSignature(bytes: Uint8Array): boolean {
    if (bytes.byteLength >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
      return true
    }
    if (bytes.byteLength >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E &&
      bytes[3] === 0x47 && bytes[4] === 0x0D && bytes[5] === 0x0A && bytes[6] === 0x1A && bytes[7] === 0x0A) {
      return true
    }
    if (bytes.byteLength >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
      bytes[3] === 0x46 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
      return true
    }
    return bytes.byteLength >= 6 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
      bytes[3] === 0x38 && (bytes[4] === 0x37 || bytes[4] === 0x39) && bytes[5] === 0x61
  }
}

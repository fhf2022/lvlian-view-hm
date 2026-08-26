import { fileIo } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { ThumbnailPolicy, ThumbnailProfile, ThumbnailSize } from './ThumbnailPolicy'

/**
 * The viewer keeps decoded pixels separate from the URI cache.  URIs are a
 * durable transport/cache concern; a PixelMap is the only object that should
 * cross the viewer's transition and source-swap boundary.
 */
export interface ViewerBitmapRecord {
  path: string
  pixelMap: image.PixelMap
  physicalWidth: number
  physicalHeight: number
  displayWidth: number
  displayHeight: number
  decodeWidth: number
  decodeHeight: number
  exifValue: string
  exifRotation: number
  mirrorHorizontal: boolean
  mirrorVertical: boolean
}

export interface ViewerBitmapMetadata {
  physicalWidth: number
  physicalHeight: number
  displayWidth: number
  displayHeight: number
  exifValue: string
  exifRotation: number
  mirrorHorizontal: boolean
  mirrorVertical: boolean
}

interface ExifTransform {
  rotation: number
  mirrorHorizontal: boolean
  mirrorVertical: boolean
}

/**
 * Image Kit decoder used by the viewer and WaterFlow.  The DMA allocator is
 * attempted first so the Image component can consume the raster without an
 * additional texture upload.  AUTO remains a safe fallback on devices or
 * formats that do not support a DMA-backed decode.
 */
export class ViewerBitmapStore {
  async readMetadata(path: string): Promise<ViewerBitmapMetadata | null> {
    let source: image.ImageSource | null = null
    let sourceFd: number = -1
    try {
      const sourceFile = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY)
      sourceFd = sourceFile.fd
      source = image.createImageSource(sourceFd)
      const info = source.getImageInfoSync()
      const physicalWidth = Math.max(1, Math.floor(info.size.width))
      const physicalHeight = Math.max(1, Math.floor(info.size.height))
      const exifValue = await this.readExif(source)
      const transform = this.transformFor(exifValue)
      const swapsAxes = transform.rotation === 90 || transform.rotation === 270
      return {
        physicalWidth: physicalWidth,
        physicalHeight: physicalHeight,
        displayWidth: swapsAxes ? physicalHeight : physicalWidth,
        displayHeight: swapsAxes ? physicalWidth : physicalHeight,
        exifValue: exifValue,
        exifRotation: transform.rotation,
        mirrorHorizontal: transform.mirrorHorizontal,
        mirrorVertical: transform.mirrorVertical
      }
    } catch (error) {
      console.warn('[UgreenBitmap] metadata failed: ' + path + ': ' + JSON.stringify(error))
      return null
    } finally {
      if (source !== null) {
        try {
          await source.release()
        } catch (_) {
        }
      }
      if (sourceFd >= 0) {
        try {
          fileIo.closeSync(sourceFd)
        } catch (_) {
        }
      }
    }
  }

  async decode(path: string, profile: ThumbnailProfile,
    desiredSize?: ThumbnailSize): Promise<ViewerBitmapRecord | null> {
    let source: image.ImageSource | null = null
    let sourceFd: number = -1
    let pixelMap: image.PixelMap | null = null
    let ownsPixelMap: boolean = false
    let allocator: string = 'DMA'
    try {
      const sourceFile = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY)
      sourceFd = sourceFile.fd
      source = image.createImageSource(sourceFd)
      const info = source.getImageInfoSync()
      const physicalWidth = Math.max(1, Math.floor(info.size.width))
      const physicalHeight = Math.max(1, Math.floor(info.size.height))
      const exifValue = await this.readExif(source)
      const transform = this.transformFor(exifValue)
      const displayWidth = transform.rotation === 90 || transform.rotation === 270
        ? physicalHeight : physicalWidth
      const displayHeight = transform.rotation === 90 || transform.rotation === 270
        ? physicalWidth : physicalHeight
      const target = desiredSize === undefined
        ? ThumbnailPolicy.targetSize(displayWidth, displayHeight, profile)
        : this.fitSize(displayWidth, displayHeight, desiredSize)
      const options: image.DecodingOptions = {
        desiredSize: { width: target.width, height: target.height },
        rotate: transform.rotation,
        editable: transform.mirrorHorizontal || transform.mirrorVertical
      }
      try {
        pixelMap = await source.createPixelMapUsingAllocator(options, image.AllocatorType.DMA)
      } catch (dmaError) {
        allocator = 'AUTO'
        console.warn('[UgreenBitmap] DMA decode fallback: ' + path + ': ' + JSON.stringify(dmaError))
        pixelMap = await source.createPixelMapUsingAllocator(options, image.AllocatorType.AUTO)
      }
      ownsPixelMap = true

      // For mirrored EXIF orientations the rotation is already performed by
      // DecodingOptions.  Reflection after that rotation is vertical for the
      // two diagonal mirror cases; the non-rotated cases retain their native
      // horizontal/vertical reflection.
      if (transform.mirrorHorizontal || transform.mirrorVertical) {
        await pixelMap.flip(transform.mirrorHorizontal, transform.mirrorVertical)
      }
      const decodedInfo = pixelMap.getImageInfoSync()
      const decodedWidth = Math.max(1, Math.floor(decodedInfo.size.width))
      const decodedHeight = Math.max(1, Math.floor(decodedInfo.size.height))
      const record: ViewerBitmapRecord = {
        path: path,
        pixelMap: pixelMap,
        physicalWidth: physicalWidth,
        physicalHeight: physicalHeight,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        decodeWidth: decodedWidth,
        decodeHeight: decodedHeight,
        exifValue: exifValue,
        exifRotation: transform.rotation,
        mirrorHorizontal: transform.mirrorHorizontal,
        mirrorVertical: transform.mirrorVertical
      }
      console.info('[UgreenBitmap] decoded path=' + path + ' allocator=' + allocator +
        ' physical=' + physicalWidth.toString() + 'x' + physicalHeight.toString() +
        ' display=' + displayWidth.toString() + 'x' + displayHeight.toString() +
        ' raster=' + decodedWidth.toString() + 'x' + decodedHeight.toString() +
        ' exif=' + exifValue)
      ownsPixelMap = false
      return record
    } catch (error) {
      console.warn('[UgreenBitmap] decode failed: ' + path + ': ' + JSON.stringify(error))
      return null
    } finally {
      if (ownsPixelMap && pixelMap !== null) {
        try {
          await pixelMap.release()
        } catch (_) {
        }
      }
      if (source !== null) {
        try {
          await source.release()
        } catch (_) {
        }
      }
      if (sourceFd >= 0) {
        try {
          fileIo.closeSync(sourceFd)
        } catch (_) {
        }
      }
    }
  }

  async release(record: ViewerBitmapRecord | null): Promise<void> {
    if (record === null) {
      return
    }
    try {
      await record.pixelMap.release()
    } catch (_) {
    }
  }

  private async readExif(source: image.ImageSource): Promise<string> {
    try {
      const value = await source.getImageProperty(image.PropertyKey.ORIENTATION)
      return typeof value === 'string' ? value : ''
    } catch (_) {
      return ''
    }
  }

  private fitSize(sourceWidth: number, sourceHeight: number,
    requested: ThumbnailSize): ThumbnailSize {
    const width = Math.max(1, Math.floor(requested.width))
    const height = Math.max(1, Math.floor(requested.height))
    const scale = Math.min(1, width / Math.max(1, sourceWidth), height / Math.max(1, sourceHeight))
    return {
      width: Math.max(1, Math.round(sourceWidth * scale)),
      height: Math.max(1, Math.round(sourceHeight * scale))
    }
  }

  private transformFor(value: string): ExifTransform {
    const normalized = value.trim().toLowerCase()
    if (normalized === 'top-right' || normalized === '2') {
      return { rotation: 0, mirrorHorizontal: true, mirrorVertical: false }
    }
    if (normalized === 'bottom-right' || normalized === '3') {
      return { rotation: 180, mirrorHorizontal: false, mirrorVertical: false }
    }
    if (normalized === 'bottom-left' || normalized === '4') {
      return { rotation: 0, mirrorHorizontal: false, mirrorVertical: true }
    }
    if (normalized === 'left-top' || normalized === '5') {
      return { rotation: 270, mirrorHorizontal: false, mirrorVertical: true }
    }
    if (normalized === 'right-top' || normalized === '6') {
      return { rotation: 90, mirrorHorizontal: false, mirrorVertical: false }
    }
    if (normalized === 'right-bottom' || normalized === '7') {
      return { rotation: 90, mirrorHorizontal: false, mirrorVertical: true }
    }
    if (normalized === 'left-bottom' || normalized === '8') {
      return { rotation: 270, mirrorHorizontal: false, mirrorVertical: false }
    }
    return { rotation: 0, mirrorHorizontal: false, mirrorVertical: false }
  }
}

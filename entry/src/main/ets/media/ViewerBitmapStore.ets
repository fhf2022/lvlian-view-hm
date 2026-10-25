import { fileIo } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { ThumbnailPolicy, ThumbnailProfile, ThumbnailSize } from './ThumbnailPolicy'
import { ImageTransformPolicy } from './ImageTransformPolicy'

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
  exifDisplayWidth: number
  exifDisplayHeight: number
  displayWidth: number
  displayHeight: number
  decodeWidth: number
  decodeHeight: number
  exifValue: string
  exifRotation: number
  mirrorHorizontal: boolean
  mirrorVertical: boolean
  userRotation: number
  transformKey: string
}

export interface ViewerBitmapMetadata {
  physicalWidth: number
  physicalHeight: number
  exifDisplayWidth: number
  exifDisplayHeight: number
  displayWidth: number
  displayHeight: number
  exifValue: string
  exifRotation: number
  mirrorHorizontal: boolean
  mirrorVertical: boolean
  userRotation: number
  transformKey: string
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
  // A native menu can outlive the WaterFlow cache entry that supplied its
  // already-decoded preview. Lease that one raster until dismissal completes.
  private previewLeases: Map<image.PixelMap, number> = new Map<image.PixelMap, number>()
  private deferredPreviewReleases: Map<image.PixelMap, ViewerBitmapRecord> =
    new Map<image.PixelMap, ViewerBitmapRecord>()

  retainPreview(record: ViewerBitmapRecord): void {
    this.previewLeases.set(record.pixelMap, (this.previewLeases.get(record.pixelMap) || 0) + 1)
  }

  async releasePreview(record: ViewerBitmapRecord): Promise<void> {
    const count = this.previewLeases.get(record.pixelMap) || 0
    if (count > 1) {
      this.previewLeases.set(record.pixelMap, count - 1)
      return
    }
    if (count === 0) {
      return
    }
    this.previewLeases.delete(record.pixelMap)
    const deferred = this.deferredPreviewReleases.get(record.pixelMap)
    this.deferredPreviewReleases.delete(record.pixelMap)
    if (deferred !== undefined) {
      await this.release(deferred)
    }
  }

  async readMetadata(path: string, userRotation: number = 0): Promise<ViewerBitmapMetadata | null> {
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
      return this.metadataForInfo(path, physicalWidth, physicalHeight, exifValue, userRotation)
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

  metadataForInfo(path: string, physicalWidth: number, physicalHeight: number,
    exifValue: string, userRotation: number = 0): ViewerBitmapMetadata {
    const transform = this.transformFor(exifValue)
    const swapsAxes = transform.rotation === 90 || transform.rotation === 270
    const normalizedUserRotation = ImageTransformPolicy.normalizedRotation(userRotation)
    const exifDisplayWidth = swapsAxes ? physicalHeight : physicalWidth
    const exifDisplayHeight = swapsAxes ? physicalWidth : physicalHeight
    const userSwapsAxes = ImageTransformPolicy.swapsAxes(normalizedUserRotation)
    return {
      physicalWidth: physicalWidth,
      physicalHeight: physicalHeight,
      exifDisplayWidth: exifDisplayWidth,
      exifDisplayHeight: exifDisplayHeight,
      displayWidth: userSwapsAxes ? exifDisplayHeight : exifDisplayWidth,
      displayHeight: userSwapsAxes ? exifDisplayWidth : exifDisplayHeight,
      exifValue: exifValue,
      exifRotation: transform.rotation,
      mirrorHorizontal: transform.mirrorHorizontal,
      mirrorVertical: transform.mirrorVertical,
      userRotation: normalizedUserRotation,
      transformKey: this.transformKey(path, exifValue, normalizedUserRotation)
    }
  }

  async decode(path: string, profile: ThumbnailProfile, userRotation: number = 0,
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
      const normalizedUserRotation = ImageTransformPolicy.normalizedRotation(userRotation)
      const exifDisplayWidth = transform.rotation === 90 || transform.rotation === 270
        ? physicalHeight : physicalWidth
      const exifDisplayHeight = transform.rotation === 90 || transform.rotation === 270
        ? physicalWidth : physicalHeight
      const userSwapsAxes = ImageTransformPolicy.swapsAxes(normalizedUserRotation)
      const displayWidth = userSwapsAxes ? exifDisplayHeight : exifDisplayWidth
      const displayHeight = userSwapsAxes ? exifDisplayWidth : exifDisplayHeight
      const finalTarget = desiredSize === undefined
        ? ThumbnailPolicy.targetSize(displayWidth, displayHeight, profile)
        : this.fitSize(displayWidth, displayHeight, desiredSize)
      // The user's quarter-turn is applied to the EXIF-normalized PixelMap
      // below. Request the pre-user-rotation axes here so the resulting
      // raster has exactly finalTarget's dimensions after that operation.
      const decodeTarget: ThumbnailSize = {
        width: userSwapsAxes ? finalTarget.height : finalTarget.width,
        height: userSwapsAxes ? finalTarget.width : finalTarget.height
      }
      const options: image.DecodingOptions = {
        desiredSize: { width: decodeTarget.width, height: decodeTarget.height },
        rotate: transform.rotation,
        editable: transform.mirrorHorizontal || transform.mirrorVertical || normalizedUserRotation !== 0
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
      // Persisted rotation is a visual edit performed after the source EXIF
      // transform. Baking it into the PixelMap makes layout and rendering use
      // the same final axes; ArkUI's post-layout .rotate() is not involved.
      if (normalizedUserRotation !== 0) {
        await pixelMap.rotate(normalizedUserRotation)
      }
      const decodedInfo = pixelMap.getImageInfoSync()
      const decodedWidth = Math.max(1, Math.floor(decodedInfo.size.width))
      const decodedHeight = Math.max(1, Math.floor(decodedInfo.size.height))
      const record: ViewerBitmapRecord = {
        path: path,
        pixelMap: pixelMap,
        physicalWidth: physicalWidth,
        physicalHeight: physicalHeight,
        exifDisplayWidth: exifDisplayWidth,
        exifDisplayHeight: exifDisplayHeight,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        decodeWidth: decodedWidth,
        decodeHeight: decodedHeight,
        exifValue: exifValue,
        exifRotation: transform.rotation,
        mirrorHorizontal: transform.mirrorHorizontal,
        mirrorVertical: transform.mirrorVertical,
        userRotation: normalizedUserRotation,
        transformKey: this.transformKey(path, exifValue, normalizedUserRotation)
      }
      console.info('[UgreenBitmap] decoded path=' + path + ' allocator=' + allocator +
        ' physical=' + physicalWidth.toString() + 'x' + physicalHeight.toString() +
        ' exifDisplay=' + exifDisplayWidth.toString() + 'x' + exifDisplayHeight.toString() +
        ' display=' + displayWidth.toString() + 'x' + displayHeight.toString() +
        ' raster=' + decodedWidth.toString() + 'x' + decodedHeight.toString() +
        ' exif=' + exifValue + ' userRotation=' + normalizedUserRotation.toString())
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
    if (this.previewLeases.has(record.pixelMap)) {
      this.deferredPreviewReleases.set(record.pixelMap, record)
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

  private transformKey(path: string, exifValue: string, userRotation: number): string {
    return path + '|exif=' + exifValue.trim().toLowerCase() +
      '|user=' + ImageTransformPolicy.normalizedRotation(userRotation).toString()
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

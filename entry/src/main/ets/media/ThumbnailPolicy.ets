export type ThumbnailProfile = 'list' | 'viewerPreview' | 'viewerZoom'

export interface ThumbnailSize {
  width: number
  height: number
}

export interface ThumbnailMetrics {
  path: string
  profile: ThumbnailProfile
  sourceBytes: number
  sourceWidth: number
  sourceHeight: number
  outputWidth: number
  outputHeight: number
  outputPixelBytes: number
  elapsedMs: number
}

/**
 * One place for all image memory budgets. The list budget is deliberately
 * independent from the size of the Image component: a small network payload
 * can still decode to a very large PixelMap.
 */
export class ThumbnailPolicy {
  static readonly LIST_MAX_DIMENSION: number = 256
  static readonly SERVER_THUMBNAIL_WARN_DIMENSION: number = 512
  static readonly SERVER_THUMBNAIL_MAX_BYTES: number = 2 * 1024 * 1024
  static readonly VIEWER_PREVIEW_MAX_DIMENSION: number = 1080
  // A longest-edge cap makes a tall original unusably soft: 1080 x 7460 was
  // reduced to 296 x 2048 and then enlarged to the full screen width. Keep
  // originals inside a bounded RGBA pixel budget instead, with a secondary
  // edge limit for pathological panoramas.
  static readonly VIEWER_ZOOM_MAX_DIMENSION: number = 8192
  static readonly VIEWER_ZOOM_MAX_PIXELS: number = 8 * 1024 * 1024
  static readonly LIST_MAX_CONCURRENT: number = 2
  static readonly MAX_PENDING_TASKS: number = 32
  static readonly BYTES_PER_RGBA_PIXEL: number = 4

  static maxDimension(profile: ThumbnailProfile): number {
    if (profile === 'viewerPreview') {
      return ThumbnailPolicy.VIEWER_PREVIEW_MAX_DIMENSION
    }
    if (profile === 'viewerZoom') {
      return ThumbnailPolicy.VIEWER_ZOOM_MAX_DIMENSION
    }
    return ThumbnailPolicy.LIST_MAX_DIMENSION
  }

  static targetSize(width: number, height: number, profile: ThumbnailProfile): ThumbnailSize {
    const sourceWidth = Math.max(1, Math.floor(width))
    const sourceHeight = Math.max(1, Math.floor(height))
    const maxDimension = ThumbnailPolicy.maxDimension(profile)
    let scale = Math.min(1, maxDimension / Math.max(sourceWidth, sourceHeight))
    if (profile === 'viewerZoom') {
      const sourcePixels = sourceWidth * sourceHeight
      scale = Math.min(scale,
        Math.sqrt(ThumbnailPolicy.VIEWER_ZOOM_MAX_PIXELS / Math.max(1, sourcePixels)))
      return {
        width: Math.max(1, Math.floor(sourceWidth * scale)),
        height: Math.max(1, Math.floor(sourceHeight * scale))
      }
    }
    return {
      width: Math.max(1, Math.round(sourceWidth * scale)),
      height: Math.max(1, Math.round(sourceHeight * scale))
    }
  }

  static estimatedPixelBytes(width: number, height: number): number {
    return Math.max(0, Math.floor(width)) * Math.max(0, Math.floor(height)) *
      ThumbnailPolicy.BYTES_PER_RGBA_PIXEL
  }

  static needsDownsample(width: number, height: number, profile: ThumbnailProfile): boolean {
    const sourceWidth = Math.max(1, Math.floor(width))
    const sourceHeight = Math.max(1, Math.floor(height))
    const target = ThumbnailPolicy.targetSize(sourceWidth, sourceHeight, profile)
    return target.width < sourceWidth || target.height < sourceHeight
  }

  /**
   * ImageSource.sampleSize downsamples both axes with the same ratio. Using a
   * ceiling here keeps the decoded long edge below the profile budget while
   * preserving the source aspect ratio for every image format.
   */
  static sampleSize(width: number, height: number, profile: ThumbnailProfile): number {
    const sourceWidth = Math.max(1, Math.floor(width))
    const sourceHeight = Math.max(1, Math.floor(height))
    const target = ThumbnailPolicy.targetSize(sourceWidth, sourceHeight, profile)
    return Math.max(1, Math.ceil(Math.max(
      sourceWidth / Math.max(1, target.width),
      sourceHeight / Math.max(1, target.height))))
  }
}

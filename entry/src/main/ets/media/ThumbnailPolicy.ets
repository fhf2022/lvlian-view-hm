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
  static readonly VIEWER_ZOOM_MAX_DIMENSION: number = 2048
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
    const scale = Math.min(1, maxDimension / Math.max(sourceWidth, sourceHeight))
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
    return Math.max(width, height) > ThumbnailPolicy.maxDimension(profile)
  }

  /**
   * ImageSource.sampleSize downsamples both axes with the same ratio. Using a
   * ceiling here keeps the decoded long edge below the profile budget while
   * preserving the source aspect ratio for every image format.
   */
  static sampleSize(width: number, height: number, profile: ThumbnailProfile): number {
    const longestSide = Math.max(1, Math.max(Math.floor(width), Math.floor(height)))
    return Math.max(1, Math.ceil(longestSide / ThumbnailPolicy.maxDimension(profile)))
  }
}

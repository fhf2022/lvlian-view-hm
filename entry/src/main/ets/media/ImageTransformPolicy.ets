export class ImageVisualSize {
  width: number = 0
  height: number = 0

  constructor(width: number, height: number) {
    this.width = Math.max(1, Math.floor(width))
    this.height = Math.max(1, Math.floor(height))
  }
}

/**
 * Pure quarter-turn geometry shared by Image Kit decoding and unit tests.
 * EXIF normalization is applied first; the persisted user rotation is always
 * a second transform over that upright visual.
 */
export class ImageTransformPolicy {
  static normalizedRotation(angle: number): number {
    const rounded = Math.round(angle / 90) * 90
    return ((rounded % 360) + 360) % 360
  }

  static swapsAxes(angle: number): boolean {
    const normalized = ImageTransformPolicy.normalizedRotation(angle)
    return normalized === 90 || normalized === 270
  }

  static rotatedSize(width: number, height: number, angle: number): ImageVisualSize {
    return ImageTransformPolicy.swapsAxes(angle)
      ? new ImageVisualSize(height, width) : new ImageVisualSize(width, height)
  }
}

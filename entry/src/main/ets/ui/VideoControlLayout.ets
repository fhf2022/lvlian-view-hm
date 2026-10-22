export interface VideoControlGeometry {
  timelineX: number
  timelineWidth: number
  timelineY: number
  timeY: number
  rotateX: number
  height: number
}

/** Adapted from HarmonyCast PlayerControlLayout; labels center on rail endpoints. */
export function videoControlGeometry(width: number): VideoControlGeometry {
  const narrow = width < 240
  return { timelineX: narrow ? 28 : 76, timelineWidth: Math.max(1, width - (narrow ? 56 : 124)),
    timelineY: narrow ? 42 : 0, timeY: narrow ? 74 : 32,
    rotateX: Math.max(72, width - 32), height: narrow ? 90 : 48 }
}

export function videoControlTime(ms: number): string {
  const seconds = Math.floor(Math.max(0, ms) / 1000)
  return Math.floor(seconds / 60).toString().padStart(2, '0') + ':' +
    (seconds % 60).toString().padStart(2, '0')
}

export function videoRatePosition(rate: number): number {
  return Math.log2(Math.max(0.25, Math.min(4, rate))) * 100
}

/** Keep 1x in the center, with the same anchors as the reference's compact panel. */
export function videoRateAt(position: number): number {
  const clamped = Math.max(-200, Math.min(200, position))
  const anchors: number[] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4]
  for (const rate of anchors) {
    if (Math.abs(clamped - videoRatePosition(rate)) <= 3) { return rate }
  }
  return Math.round(Math.pow(2, clamped / 100) * 20) / 20
}

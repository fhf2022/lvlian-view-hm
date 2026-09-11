/** Window coordinates in vp, shared only while the import control is touched. */
export class ImportLightState {
  x: number = 0
  y: number = 0
  active: boolean = false

  constructor(x: number = 0, y: number = 0, active: boolean = false) {
    this.x = x
    this.y = y
    this.active = active
  }
}

export class ProximityLighting {
  // Measured from the ball centre: 112vp beyond its 28vp radius.
  static readonly RANGE: number = 140

  static strength(x: number, y: number, nx: number, ny: number,
    sourceX: number, sourceY: number): number {
    const dx = sourceX - x
    const dy = sourceY - y
    const distance = Math.sqrt(dx * dx + dy * dy)
    if (distance >= ProximityLighting.RANGE || distance < 0.001) { return 0 }
    const facing = Math.max(0, (nx * dx + ny * dy) / distance)
    const t = 1 - distance / ProximityLighting.RANGE
    return facing * t * t * (3 - 2 * t)
  }
}

/** Counts finger travel after contacting a resource boundary, never scroll
 * deltas (which also include flings, programmatic jumps and spring frames). */
export class WaterfallEdgePull {
  static readonly THRESHOLD: number = 56
  private pointer: number = -1
  private startX: number = 0
  private startY: number = 0
  private y: number = 0
  private edge: number = 0
  private distance: number = 0

  begin(pointer: number, x: number, y: number): void {
    this.cancel()
    this.pointer = pointer; this.startX = x; this.startY = y; this.y = y
  }

  contact(edge: number): void {
    if (this.pointer >= 0 && this.edge === 0) { this.edge = edge }
  }

  move(pointer: number, x: number, y: number): void {
    if (this.pointer < 0) { return }
    if (pointer !== this.pointer || (Math.abs(x - this.startX) > 16 &&
      Math.abs(x - this.startX) > Math.abs(y - this.startY))) { this.cancel(); return }
    if (this.edge !== 0) {
      this.distance = Math.max(0, this.distance + (this.y - y) * this.edge)
      if (this.distance === 0) { this.edge = 0 }
    }
    this.y = y
  }

  fingerDirection(y: number): number { return this.pointer < 0 || y === this.y ? 0 : (y > this.y ? -1 : 1) }
  holding(): boolean { return this.pointer >= 0 && this.distance > 0 }
  offset(): number { return -this.edge * Math.min(64, this.distance * 0.5) }

  release(): number {
    const edge = this.distance >= WaterfallEdgePull.THRESHOLD ? this.edge : 0
    this.cancel()
    return edge
  }

  cancel(): void { this.pointer = -1; this.edge = 0; this.distance = 0 }
}

/** Edge scrolling uses window coordinates and returns vp per second. */
export class DragSelectionScrollPolicy {
  static velocity(y: number, top: number, bottom: number): number {
    if (!Number.isFinite(y) || !Number.isFinite(top) || !Number.isFinite(bottom) || bottom <= top) {
      return 0
    }
    const edge = Math.min(56, (bottom - top) / 3)
    let depth = 0
    let direction = 0
    if (y < top + edge) {
      depth = (top + edge - y) / edge
      direction = -1
    } else if (y > bottom - edge) {
      depth = (y - bottom + edge) / edge
      direction = 1
    } else {
      return 0
    }
    depth = Math.min(1, Math.max(0, depth))
    return direction * (72 + 648 * depth * depth)
  }

  static step(velocity: number, elapsedMs: number): number {
    // A delayed frame must not turn into a large jump after the JS thread resumes.
    return velocity * Math.max(0, Math.min(32, elapsedMs)) / 1000
  }
}

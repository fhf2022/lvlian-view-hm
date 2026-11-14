export type PadDirection = 'left' | 'right' | 'up' | 'down' | ''

export interface GamepadFocusPosition {
  id: string
  index: number
}

/** Stable item identity survives sorting, while index provides a deletion fallback. */
export class GamepadFocusHistory {
  private positions: Map<string, GamepadFocusPosition> = new Map<string, GamepadFocusPosition>()

  remember(scope: string, id: string, index: number): void {
    if (id === '') { return }
    this.positions.delete(scope)
    this.positions.set(scope, { id: id, index: index })
    if (this.positions.size > 128) { this.positions.delete(this.positions.keys().next().value) }
  }

  get(scope: string): GamepadFocusPosition | undefined { return this.positions.get(scope) }
}

export class GamepadNavigation {
  static readonly engage: number = 0.52
  static readonly release: number = 0.27
  static readonly repeatDelayMs: number = 430

  static repeatInterval(magnitude: number, viewer: boolean): number {
    const threshold = 0.72
    if (magnitude < threshold) { return 0 }
    const tilt = (Math.min(1, magnitude) - threshold) / (1 - threshold)
    // Keep the viewer interval above the page animation duration.
    return Math.round(viewer ? 480 - 220 * tilt : 225 - 125 * tilt)
  }

  static axis(value: number): number {
    return Number.isFinite(value) ? Math.max(-1, Math.min(1, value)) : 0
  }

  static analog(value: number): number {
    const clamped = GamepadNavigation.axis(value)
    const magnitude = Math.max(0, (Math.abs(clamped) - 0.19) / 0.81)
    return Math.sign(clamped) * magnitude
  }

  static direction(x: number, y: number, threshold: number): PadDirection {
    if (Math.max(Math.abs(x), Math.abs(y)) < threshold) { return '' }
    if (Math.abs(x) >= Math.abs(y)) { return x < 0 ? 'left' : 'right' }
    return y < 0 ? 'up' : 'down'
  }

  static gridNeighbor(index: number, count: number, columns: number, direction: PadDirection): number {
    if (index < 0 || index >= count || columns < 1) { return -1 }
    const column = index % columns
    if (direction === 'left' && column > 0) { return index - 1 }
    if (direction === 'right' && column + 1 < columns && index + 1 < count) { return index + 1 }
    if (direction === 'up' && index >= columns) { return index - columns }
    if (direction === 'down' && index - column + columns < count) {
      return Math.min(index + columns, count - 1)
    }
    return -1
  }
}

export class GamepadStickRepeat {
  private direction: PadDirection = ''
  private latched: boolean = false
  private magnitude: number = 0
  private repeatAt: number = 0

  reset(): void {
    this.direction = ''
    this.latched = false
    this.magnitude = 0
    this.repeatAt = 0
  }

  sample(x: number, y: number, now: number): PadDirection {
    this.magnitude = Math.max(Math.abs(x), Math.abs(y))
    if (this.magnitude < GamepadNavigation.release) { this.reset(); return '' }
    this.direction = GamepadNavigation.direction(x, y, GamepadNavigation.engage)
    if (this.direction === '' || this.latched) { return '' }
    this.latched = true
    this.repeatAt = now + GamepadNavigation.repeatDelayMs
    return this.direction
  }

  tick(now: number): PadDirection {
    if (!this.latched || this.direction === '' || now < this.repeatAt) { return '' }
    const interval = GamepadNavigation.repeatInterval(this.magnitude, false)
    if (interval === 0) { return '' }
    this.repeatAt = now + interval
    return this.direction
  }
}

/** ArkUI and Game Controller Kit can report the same physical press. */
export class GamepadPressFilter {
  private downAt: Map<number, number> = new Map<number, number>()
  private held: Set<number> = new Set<number>()

  accept(code: number, down: boolean, now: number): boolean {
    if (!down) {
      this.held.delete(code)
      return true
    }
    const previous = this.downAt.get(code)
    const alreadyHeld = this.held.has(code)
    this.downAt.set(code, now)
    this.held.add(code)
    return !alreadyHeld && (previous === undefined || now - previous >= 40)
  }

  reset(): void {
    this.downAt.clear()
    this.held.clear()
  }
}

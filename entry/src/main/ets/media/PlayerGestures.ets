export interface PlayerGestureState {
  width: number
  positionMs: number
  durationMs: number
  rate: number
  playing: boolean
  brightness: number
  volume: number
}

export interface PlayerGestureActions {
  tap: () => void
  togglePlay: () => void
  seek: (positionMs: number) => void
  rate: (rate: number) => void
  brightness: (value: number) => void
  volume: (value: number) => void
  preview: (kind: string, value: number) => void
  active: (active: boolean) => void
}

/** One axis per touch; a pending single tap never fires after a double tap or drag. */
export class PlayerGestures {
  private actions: PlayerGestureActions
  private state: PlayerGestureState | null = null
  private x: number = 0
  private y: number = 0
  private axis: string = ''
  private value: number = 0
  private holding: boolean = false
  private holdTimer: number = -1
  private tapTimer: number = -1
  private levelTimer: number = -1
  private lastTap: number = -1
  private secondTap: boolean = false

  constructor(actions: PlayerGestureActions) { this.actions = actions }
  isActive(): boolean { return this.state !== null }

  down(x: number, y: number, state: PlayerGestureState): void {
    if (this.state !== null) { this.cancel() }
    this.secondTap = this.tapTimer >= 0 && Date.now() - this.lastTap <= 280
    if (this.secondTap) { clearTimeout(this.tapTimer); this.tapTimer = -1 }
    this.state = state
    this.x = x
    this.y = y
    this.axis = ''
    this.actions.active(true)
    this.holdTimer = setTimeout((): void => {
      this.holdTimer = -1
      if (this.state !== null && this.axis.length === 0 && this.state.playing) {
        this.clearTap()
        this.holding = true
        this.actions.rate(2)
        this.actions.preview('speed', 2)
      }
    }, 350)
  }

  move(x: number, y: number): void {
    const state = this.state
    if (state === null || this.holding) { return }
    const dx = x - this.x, dy = y - this.y
    if (this.axis.length === 0 && Math.max(Math.abs(dx), Math.abs(dy)) > 10) {
      this.clearHold()
      this.clearTap()
      this.axis = Math.abs(dx) >= Math.abs(dy) ? 'seek'
        : this.x < state.width / 2 ? 'brightness' : 'volume'
    }
    if (this.axis === 'seek') {
      this.value = Math.max(0, Math.min(state.durationMs, state.positionMs + dx * 150))
    } else if (this.axis === 'brightness' || this.axis === 'volume') {
      const initial = this.axis === 'brightness' ? state.brightness : state.volume
      this.value = Math.round(Math.max(0, Math.min(100, initial - dy * .3)))
      if (this.levelTimer < 0) {
        this.levelTimer = setTimeout((): void => { this.levelTimer = -1; this.writeLevel() }, 80)
      }
    } else { return }
    this.actions.preview(this.axis, this.value)
  }

  up(): void {
    const state = this.state
    if (state === null) { return }
    this.clearHold()
    this.clearLevel()
    if (this.holding) {
      this.actions.rate(state.rate)
    } else if (this.axis === 'seek' && state.durationMs > 0) {
      this.actions.seek(this.value)
    } else if (this.axis === 'brightness' || this.axis === 'volume') {
      this.writeLevel()
    } else if (this.axis.length === 0) {
      if (this.secondTap) {
        this.clearTap()
        this.actions.togglePlay()
      } else {
        this.lastTap = Date.now()
        this.tapTimer = setTimeout((): void => {
          this.tapTimer = -1
          this.actions.tap()
        }, 280)
      }
    }
    this.finish()
  }

  cancel(restoreRate: boolean = true): void {
    this.clearHold()
    this.clearLevel()
    this.clearTap()
    if (this.holding && this.state !== null && restoreRate) { this.actions.rate(this.state.rate) }
    this.finish()
  }

  private finish(): void {
    this.state = null
    this.axis = ''
    this.holding = false
    this.secondTap = false
    this.actions.preview('', 0)
    this.actions.active(false)
  }

  private writeLevel(): void {
    if (this.state === null) { return }
    if (this.axis === 'brightness') { this.actions.brightness(this.value) }
    else if (this.axis === 'volume') { this.actions.volume(this.value) }
  }

  private clearHold(): void { if (this.holdTimer >= 0) { clearTimeout(this.holdTimer); this.holdTimer = -1 } }
  private clearLevel(): void { if (this.levelTimer >= 0) { clearTimeout(this.levelTimer); this.levelTimer = -1 } }
  private clearTap(): void {
    if (this.tapTimer >= 0) { clearTimeout(this.tapTimer); this.tapTimer = -1 }
    this.lastTap = -1
    this.secondTap = false
  }
}

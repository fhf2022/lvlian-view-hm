import { KeyCode } from '@kit.InputKit'
import { GamepadNavigation, GamepadStickRepeat, PadDirection } from './GamepadNavigation'

export interface ModalFocusTarget {
  id: string
  activate: () => void
  reveal?: () => void
}

/** Owns the selection and the button press that belongs to one visible modal. */
export class GamepadModalFocus {
  readonly id: string
  readonly systemContent: boolean
  private readonly targets: () => ModalFocusTarget[]
  private readonly drawFocus: (id: string) => void
  private readonly back: () => void
  private readonly preferred: () => string
  private readonly adjust: (direction: PadDirection, id: string) => boolean
  private selected: string = ''
  private confirmHeld: string = ''
  private confirmDown: boolean = false
  private backHeld: boolean = false
  private directionKeys: Set<number> = new Set<number>()
  private readonly stick: GamepadStickRepeat = new GamepadStickRepeat()
  private hat: PadDirection = ''
  private lastDigitalDirection: PadDirection = ''
  private lastDigitalAt: number = 0

  constructor(id: string, targets: () => ModalFocusTarget[], drawFocus: (id: string) => void,
    back: () => void, preferred: () => string = (): string => '',
    adjust: (direction: PadDirection, id: string) => boolean = (): boolean => false, systemContent: boolean = false) {
    this.id = id
    this.systemContent = systemContent
    this.targets = targets
    this.drawFocus = drawFocus
    this.back = back
    this.preferred = preferred
    this.adjust = adjust
  }

  focusInitial(): boolean {
    if (this.systemContent) { this.drawFocus(''); return false }
    const items = this.targets()
    if (items.some((item: ModalFocusTarget): boolean => item.id === this.selected)) {
      this.drawFocus(this.selected)
      return false
    }
    const preferred = items.find((item: ModalFocusTarget): boolean => item.id === this.preferred())
    this.select(preferred ?? items[0])
    return true
  }

  reset(): void {
    this.suspend()
    this.selected = ''
  }

  suspend(): void {
    this.confirmHeld = ''
    this.confirmDown = false
    this.backHeld = false
    this.directionKeys.clear()
    this.stick.reset()
    this.hat = ''
    this.lastDigitalDirection = ''
    this.lastDigitalAt = 0
    this.drawFocus('')
  }

  static directionForKey(code: number): PadDirection {
    switch (code) {
      case KeyCode.KEYCODE_DPAD_LEFT: return 'left'
      case KeyCode.KEYCODE_DPAD_RIGHT: return 'right'
      case KeyCode.KEYCODE_DPAD_UP: return 'up'
      case KeyCode.KEYCODE_DPAD_DOWN: return 'down'
      default: return ''
    }
  }

  key(code: number, down: boolean): boolean {
    if (code === KeyCode.KEYCODE_BUTTON_B) {
      if (down) { this.backHeld = true }
      else if (this.backHeld) { this.backHeld = false; this.back() }
      return true
    }
    if (this.systemContent) { return false }
    if (code === KeyCode.KEYCODE_BUTTON_A) {
      if (down) {
        if (!this.confirmDown) {
          this.confirmDown = true
          this.focusInitial()
          this.confirmHeld = this.selected
        }
      } else {
        const id = this.confirmHeld
        this.confirmDown = false
        this.confirmHeld = ''
        if (id !== '' && id === this.selected) {
          this.targets().find((item: ModalFocusTarget): boolean => item.id === id)?.activate()
        }
      }
      return true
    }
    const direction = GamepadModalFocus.directionForKey(code)
    if (direction === '') { return false }
    if (!down) { this.directionKeys.delete(code); return true }
    if (!this.directionKeys.has(code)) {
      this.directionKeys.add(code)
      if (this.hat !== direction) { this.move(direction) }
      this.lastDigitalDirection = direction
      this.lastDigitalAt = Date.now()
    }
    return true
  }

  axis(x: number, y: number, isHat: boolean): void {
    if (this.systemContent) { return }
    if (isHat) {
      const direction = GamepadNavigation.direction(x, y, GamepadNavigation.engage)
      const old = this.hat
      this.hat = direction
      if (direction !== '' && direction !== old &&
        (direction !== this.lastDigitalDirection || Date.now() - this.lastDigitalAt > 120)) {
        this.move(direction)
      }
      return
    }
    const direction = this.stick.sample(x, y, Date.now())
    if (direction !== '') { this.move(direction) }
  }

  tick(): void {
    const direction = this.stick.tick(Date.now())
    if (direction !== '') { this.move(direction) }
  }

  private move(direction: PadDirection): void {
    this.confirmHeld = ''
    if (this.focusInitial() || this.adjust(direction, this.selected)) { return }
    const items = this.targets()
    const index = items.findIndex((item: ModalFocusTarget): boolean => item.id === this.selected)
    const next = index + (direction === 'left' || direction === 'up' ? -1 : 1)
    if (next >= 0 && next < items.length) { this.select(items[next]) }
  }

  private select(target: ModalFocusTarget | undefined): void {
    const id = target?.id ?? ''
    if (id === this.selected) { return }
    this.selected = id
    this.drawFocus(id)
    target?.reveal?.()
  }
}

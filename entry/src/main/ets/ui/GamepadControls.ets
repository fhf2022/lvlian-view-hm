import { AttributeUpdater, ColorMetrics, LengthMetrics, UIContext } from '@kit.ArkUI'
import { PadDirection } from './GamepadNavigation'

export interface GamepadControlOptions {
  adjust?: (direction: PadDirection) => boolean
  hold?: () => void
  reveal?: () => void
  nativeFocus?: boolean
  // Material controls retain their own icon/light treatment.
  highlight?: (selected: boolean) => void
}

interface ControlTarget {
  id: string
  scope: string
  action: () => void
  enabled: () => boolean
  context: UIContext
  options: GamepadControlOptions
  draw: (selected: boolean) => void
  x: number
  y: number
  mounted: boolean
}

/** One action callback for touch and gamepad; scopes retain the entrance on return. */
export class GamepadControls {
  private static targets: Map<string, ControlTarget> = new Map<string, ControlTarget>()
  private static selected: Map<string, string> = new Map<string, string>()
  private static active: string = ''
  private static pressed: string = ''
  private static holdTimer: number = -1

  static register(target: ControlTarget): void {
    const old = GamepadControls.targets.get(target.id)
    if (old !== undefined) {
      target.x = old.x; target.y = old.y; target.mounted = old.mounted
    }
    target.mounted = true
    GamepadControls.targets.set(target.id, target)
  }

  static remove(target: ControlTarget): void {
    if (GamepadControls.targets.get(target.id) !== target) { return }
    GamepadControls.targets.delete(target.id)
    if (GamepadControls.pressed === target.id) { GamepadControls.cancelPress() }
  }

  static mount(id: string, area?: Area): void {
    const target = GamepadControls.targets.get(id)
    if (target === undefined) { return }
    target.mounted = true
    if (area !== undefined) {
      target.x = Number(area.globalPosition.x) + Number(area.width) / 2
      target.y = Number(area.globalPosition.y) + Number(area.height) / 2
    }
  }

  static isSelected(scope: string, id: string): boolean {
    return scope !== '' && GamepadControls.active === scope && GamepadControls.selected.get(scope) === id
  }

  static setScope(scope: string): void {
    if (scope === GamepadControls.active) { return }
    GamepadControls.cancelPress()
    GamepadControls.targets.get(GamepadControls.selected.get(GamepadControls.active) ?? '')?.draw(false)
    GamepadControls.active = scope
    const next = GamepadControls.targets.get(GamepadControls.selected.get(scope) ?? '')
    if (next?.mounted && next.enabled()) { next.draw(true) }
  }

  private static available(scope: string): ControlTarget[] {
    if (scope === '') { return [] }
    return Array.from(GamepadControls.targets.values()).filter((target: ControlTarget): boolean =>
      target.scope === scope && target.mounted && target.enabled())
  }

  static focus(scope: string): boolean {
    GamepadControls.setScope(scope)
    const targets = GamepadControls.available(scope)
    const target = targets.find((item: ControlTarget): boolean => item.id === GamepadControls.selected.get(scope)) ?? targets[0]
    if (target === undefined) { return false }
    GamepadControls.select(target)
    return true
  }

  private static select(target: ControlTarget): void {
    const previous = GamepadControls.targets.get(GamepadControls.selected.get(target.scope) ?? '')
    if (previous?.id !== target.id) {
      GamepadControls.cancelPress()
      previous?.draw(false)
    }
    GamepadControls.selected.set(target.scope, target.id)
    target.options.reveal?.()
    // Logical selection also works inside native subtrees that refuse requestFocus.
    // Inputs start native editing on A, rather than when moving past a field.
    if (target.options.nativeFocus !== false) {
      try { target.context.getFocusController().requestFocus(target.id) } catch (_) {}
    }
    target.draw(true)
  }

  static touch(scope: string, id: string, action: () => void): void {
    if (scope !== '') { GamepadControls.selected.set(scope, id) }
    action()
  }

  static activate(scope: string): void {
    const target = GamepadControls.available(scope).find((item: ControlTarget): boolean =>
      item.id === GamepadControls.selected.get(scope))
    if (target === undefined) { GamepadControls.focus(scope); return }
    target.action()
  }

  static cancelPress(): void {
    if (GamepadControls.holdTimer >= 0) { clearTimeout(GamepadControls.holdTimer) }
    GamepadControls.holdTimer = -1
    GamepadControls.pressed = ''
  }

  static confirm(scope: string, down: boolean): void {
    if (!down) {
      const id = GamepadControls.pressed
      GamepadControls.cancelPress()
      if (scope === GamepadControls.active && id !== '' && id === GamepadControls.selected.get(scope)) {
        GamepadControls.activate(scope)
      }
      return
    }
    if (GamepadControls.pressed !== '') { return }
    if (!GamepadControls.available(scope).some((item: ControlTarget): boolean =>
      item.id === GamepadControls.selected.get(scope))) { GamepadControls.focus(scope) }
    const target = GamepadControls.targets.get(GamepadControls.selected.get(scope) ?? '')
    if (target === undefined || !target.enabled()) { return }
    GamepadControls.pressed = target.id
    if (target.options.hold === undefined) { return }
    GamepadControls.holdTimer = setTimeout((): void => {
      const current = GamepadControls.targets.get(target.id)
      const valid = scope === GamepadControls.active && GamepadControls.pressed === target.id &&
        current?.mounted === true && current.enabled()
      GamepadControls.cancelPress()
      if (valid) { current?.options.hold?.() }
    }, 500)
  }

  static move(scope: string, direction: PadDirection): void {
    GamepadControls.setScope(scope)
    GamepadControls.cancelPress()
    const targets = GamepadControls.available(scope)
    const current = targets.find((item: ControlTarget): boolean => item.id === GamepadControls.selected.get(scope))
    if (current === undefined) { GamepadControls.focus(scope); return }
    if (current.options.adjust?.(direction)) { return }
    let nearest: ControlTarget | undefined = undefined
    let score = Number.POSITIVE_INFINITY
    for (const item of targets) {
      const dx = item.x - current.x; const dy = item.y - current.y
      const horizontal = direction === 'left' || direction === 'right'
      const forward = direction === 'left' ? -dx : direction === 'right' ? dx : direction === 'up' ? -dy : dy
      const distance = forward + Math.abs(horizontal ? dy : dx) * 2
      if (forward > 1 && distance < score) { nearest = item; score = distance }
    }
    if (nearest !== undefined) { GamepadControls.select(nearest) }
  }
}

/** Only actions opt in. Containers, titles, layout and touch gestures are untouched. */
export class GamepadAction extends AttributeUpdater<CommonAttribute> {
  private target: ControlTarget
  private bindClick: boolean

  constructor(context: UIContext, scope: string, key: string, action: () => void,
    enabled: () => boolean = (): boolean => true, nodeId: string = '', bindClick: boolean = true,
    options: GamepadControlOptions = {}) {
    super()
    this.bindClick = bindClick
    this.target = { id: nodeId || 'pad-control:' + (scope.startsWith('settings:') ? 'settings' : scope) + ':' + key, scope: scope, action: action,
      enabled: enabled, context: context, options: options, x: 0, y: 0, mounted: false,
      draw: (selected: boolean): void => {
        if (options.highlight !== undefined) { options.highlight(selected); return }
        context.runScopedTask((): void => {
          this.attribute?.shadow({ radius: selected ? 9 : 0, color: '#805F9BF2', offsetX: 0, offsetY: 0 })
        })
      } }
  }

  initializeModifier(instance: CommonAttribute): void { this.applyNormalAttribute(instance) }

  applyNormalAttribute(instance: CommonAttribute): void {
    const target = this.target
    if (this.bindClick) { instance.onClick((): void => GamepadControls.touch(target.scope, target.id, target.action)) }
    // Manual file/viewer controls keep their original focus registration.
    if (target.scope === '') { return }
    GamepadControls.register(target)
    instance.id(target.id).focusable(true)
      .focusBox({ strokeColor: ColorMetrics.resourceColor(Color.Transparent), strokeWidth: LengthMetrics.vp(0) })
      .onAppear((): void => GamepadControls.mount(target.id))
      .onDisAppear((): void => GamepadControls.remove(target))
      .onAreaChange((_, area: Area): void => GamepadControls.mount(target.id, area))
    if (target.options.highlight === undefined) {
      instance.shadow({ radius: GamepadControls.isSelected(target.scope, target.id) ? 9 : 0,
        color: '#805F9BF2', offsetX: 0, offsetY: 0 })
    }
  }
}

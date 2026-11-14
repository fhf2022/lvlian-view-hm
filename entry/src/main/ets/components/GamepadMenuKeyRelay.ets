import { UIContext, ColorMetrics, LengthMetrics } from '@kit.ArkUI'
import { DEBUG } from 'BuildProfile'

/** Observe menu keys before ArkUI dispatch, without needing a focused visual control. */
export class GamepadMenuKeyInput {
  private context: UIContext | null = null
  private monitor: InputEventMonitor | null = null

  attach(context: UIContext, onKey: (event: KeyEvent) => boolean): void {
    this.detach()
    try {
      this.monitor = context.addLocalInputEventMonitor(InputEventSubTypeMask.KEY_DOWN | InputEventSubTypeMask.KEY_UP,
        (wrapper: RawInputEventWrapper): InputEventInterceptResult => {
          const event = wrapper.asKeyEvent()
          if (event !== null) { onKey(event) }
          // Keep the down/up pair in ArkUI's key lifecycle. Component handlers
          // consume supported keys; the shared press filter deduplicates delivery.
          return { action: InputEventInterceptAction.CONTINUE }
        })
      this.context = context
    } catch (error) {
      console.warn('[LinkFilesGamepad] menu key listener unavailable: ' + JSON.stringify(error))
    }
  }

  detach(): void {
    const monitor = this.monitor
    if (monitor !== null) { this.context?.removeLocalInputEventMonitor(monitor) }
    this.context = null
    this.monitor = null
  }
}

/** Shared input receiver for native long-press menus and floating popups. */
@Component
export struct GamepadMenuKeyRelay {
  @Prop inputId: string = 'context-menu-gamepad-input'
  onKey: (event: KeyEvent) => boolean = (_event: KeyEvent): boolean => false
  shouldFocus: () => boolean = () => false
  onAxis: (event: FocusAxisEvent) => void = () => {}
  private input: GamepadMenuKeyInput = new GamepadMenuKeyInput()
  private focusTimer: number = -1

  aboutToAppear(): void {
    this.input.attach(this.getUIContext(), this.onKey)
  }

  aboutToDisappear(): void {
    this.input.detach()
    if (this.focusTimer >= 0) { clearTimeout(this.focusTimer) }
    this.focusTimer = -1
  }

  build() {
    Row() {}.width(1).height(1).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .id(this.inputId).focusable(true).defaultFocus(true)
      .focusBox({ strokeColor: ColorMetrics.resourceColor(Color.Transparent), strokeWidth: LengthMetrics.vp(0) })
      .onKeyPreIme((event: KeyEvent): boolean => this.onKey(event))
      .onKeyEventDispatch((event: KeyEvent): boolean => this.onKey(event))
      .onFocusAxisEvent((event: FocusAxisEvent): void => this.onAxis(event))
      .onAppear((): void => {
        this.focusTimer = setTimeout((): void => {
          this.focusTimer = -1
          if (!this.shouldFocus()) { return }
          try {
            this.getUIContext().getFocusController().requestFocus(this.inputId)
          } catch (error) {
            if (DEBUG) { console.info('[LinkFilesGamepad] context menu focus: ' + JSON.stringify(error)) }
          }
        }, 0)
      })
  }
}

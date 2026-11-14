import { ColorMetrics, LengthMetrics } from '@kit.ArkUI'
import { GlassControlGeometry as Glass } from '../ui/GlassControlGeometry'
import { GamepadMenuKeyRelay } from './GamepadMenuKeyRelay'

/** Content only: bindPopup owns the single native glass surface. */
@Component
export struct GlassMenuSurface {
  @Prop widthVp: number = Glass.menuWidth
  onPadKey: (event: KeyEvent) => boolean = (_event: KeyEvent): boolean => false
  onPadAxis: (event: FocusAxisEvent) => void = (_event: FocusAxisEvent): void => {}
  shouldFocus: () => boolean = () => false
  @BuilderParam content: () => void

  build() {
    Column() {
      this.content()
      // Absolute positioning leaves the original content size/padding unchanged.
      // The relay owns native focus and early key monitoring, never a painted row.
      GamepadMenuKeyRelay({ inputId: 'floating-menu-gamepad-input',
        onKey: this.onPadKey, onAxis: this.onPadAxis, shouldFocus: this.shouldFocus })
        .position({ x: 0, y: 0 })
    }
      .width(this.widthVp)
      .padding({ left: Glass.menuPadding, right: Glass.menuPadding,
        top: Glass.menuVerticalPadding, bottom: Glass.menuVerticalPadding })
      .borderRadius(Glass.menuRadius)
      .hitTestBehavior(HitTestMode.Default)
      .focusable(true)
      .focusBox({ strokeColor: ColorMetrics.resourceColor(Color.Transparent), strokeWidth: LengthMetrics.vp(0) })
      .onKeyPreIme((event: KeyEvent): boolean => this.onPadKey(event))
      .onKeyEventDispatch((event: KeyEvent): boolean => this.onPadKey(event))
      .onFocusAxisEvent((event: FocusAxisEvent): void => this.onPadAxis(event))
  }
}

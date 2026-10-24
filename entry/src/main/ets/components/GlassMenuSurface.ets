import { GlassControlGeometry as Glass } from '../ui/GlassControlGeometry'

/** Content only: bindPopup owns the single native glass surface. */
@Component
export struct GlassMenuSurface {
  @Prop widthVp: number = Glass.menuWidth
  @BuilderParam content: () => void

  build() {
    Column() { this.content() }
      .width(this.widthVp)
      .padding({ left: Glass.menuPadding, right: Glass.menuPadding,
        top: Glass.menuVerticalPadding, bottom: Glass.menuVerticalPadding })
      .borderRadius(Glass.menuRadius)
      .hitTestBehavior(HitTestMode.Default)
  }
}

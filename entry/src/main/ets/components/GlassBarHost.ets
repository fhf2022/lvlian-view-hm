import { GlassControlGeometry as Glass } from '../ui/GlassControlGeometry'

/** Supported material scope, with real renderer space beyond the 56vp body.
 * This host is transparent to input. Its authored controls own their bounds.
 */
@Component
export struct GlassBarHost {
  @Prop bottomInset: number = 0
  @BuilderParam content: () => void
  onHostAreaChange: (area: Area) => void = () => {}

  @Builder
  private BarContent(): void {
    Stack({ alignContent: Alignment.Bottom }) {
      this.content()
    }
    .width('100%')
    .height(Glass.barHeight + Glass.barEffectTop)
    .margin({ bottom: Glass.nativeBarOffset })
    .clip(false)
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {}.tabBar(this.BarContent)
    }
    .vertical(false).scrollable(false).barOverlap(true)
    .barHeight(Glass.barSlotHeight)
    .barBackgroundColor(Color.Transparent).barBackgroundBlurStyle(BlurStyle.NONE)
    .width('100%').height(Glass.barHostHeight)
    .margin({ bottom: this.bottomInset - Glass.nativeBarOffset })
    .clip(false).hitTestBehavior(HitTestMode.None)
    .onAreaChange((_, area: Area) => this.onHostAreaChange(area))
  }
}

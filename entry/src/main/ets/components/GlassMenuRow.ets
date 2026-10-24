import { GlassControlGeometry as Glass } from '../ui/GlassControlGeometry'

/** All anchored More menus share one row; the owner supplies the action/slide group. */
@Component
export struct GlassMenuRow {
  @Prop icon: Resource = $r('sys.symbol.more')
  @Prop title: string = ''
  @Prop showDivider: boolean = true
  @Prop rowId: string = ''
  onActivate: () => void = () => {}
  onRowTouch: (event: TouchEvent) => void = () => {}
  onRowArea: (area: Area) => void = () => {}

  build() {
    Column() {
      Button() {
        Row() {
          Text(this.title).fontSize(16).fontColor($r('sys.color.font_primary')).layoutWeight(1)
          SymbolGlyph(this.icon).fontSize(22).fontColor([$r('sys.color.icon_primary')]).width(32)
        }
        .width('100%').height('100%').padding({ left: 10, right: 8 })
      }
      .id(this.rowId)
      .type(ButtonType.Normal).width('100%').height(Glass.menuRowHeight)
      .padding(0).borderRadius(14).backgroundColor(Color.Transparent).stateEffect(true)
      .onAreaChange((_, area: Area) => this.onRowArea(area))
      .onTouch((event: TouchEvent) => this.onRowTouch(event))
      .onClick(() => this.onActivate())

      if (this.showDivider) {
        Divider().strokeWidth(0.5).color($r('sys.color.comp_divider')).margin({ left: 10, right: 10 })
      }
    }
    .width('100%')
  }
}

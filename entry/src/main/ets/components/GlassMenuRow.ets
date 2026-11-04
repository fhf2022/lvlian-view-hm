import { GlassControlGeometry as Glass } from '../ui/GlassControlGeometry'
import { ContentDivider } from './ContentDivider'

/** 菜单行版式：glass = 悬浮玻璃菜单，menu = 长按上下文菜单（尺寸与内边距更紧凑）。 */
export type MenuRowVariant = 'glass' | 'menu'

/**
 * 所有「图标 + 文字 + 分隔线」菜单行共用一份实现，owner 只提供动作与滑动分组。
 * 上下文菜单原先另抄了一份同样的版式（ActionMenuRow），只差尺寸/内边距/警示色；
 * 合并后差异全部走 variant + danger，行内容只此一份。
 *
 * 容器保持两种：玻璃菜单用 Button（需要按压反馈），上下文菜单用 Column
 * （它是自绘面板里的行，不能被 Button 抢走「按下 A 滑到 B」的手势）。
 */
@Component
export struct GlassMenuRow {
  @Prop icon: Resource = $r('sys.symbol.more')
  @Prop title: string = ''
  @Prop showDivider: boolean = true
  @Prop rowId: string = ''
  @Prop variant: MenuRowVariant = 'glass'
  @Prop danger: boolean = false
  onActivate: () => void = () => {}
  onRowTouch: (event: TouchEvent) => void = () => {}
  onRowArea: (area: Area) => void = () => {}

  private compact(): boolean {
    return this.variant === 'menu'
  }

  private rowHeight(): number {
    return this.compact() ? 50 : Glass.menuRowHeight
  }

  private titleColor(): ResourceColor {
    return this.danger ? $r('sys.color.warning') : $r('sys.color.font_primary')
  }

  private iconColor(): ResourceColor {
    return this.danger ? $r('sys.color.warning') : $r('sys.color.icon_primary')
  }

  @Builder
  RowContent(): void {
    Row() {
      Text(this.title)
        .fontSize(16)
        .fontColor(this.titleColor())
        .layoutWeight(1)
      SymbolGlyph(this.icon)
        .fontSize(this.compact() ? 21 : 22)
        .fontColor([this.iconColor()])
        .width(this.compact() ? 30 : 32)
    }
    .width('100%').height('100%')
    .padding(this.compact() ? { left: 16, right: 10 } : { left: 10, right: 8 })
  }

  build() {
    Column() {
      if (this.compact()) {
        Column() {
          this.RowContent()
        }
        .id(this.rowId)
        .width('100%')
        .height(this.rowHeight())
        .backgroundColor(Color.Transparent)
        .onAreaChange((_, area: Area) => this.onRowArea(area))
        .onTouch((event: TouchEvent) => this.onRowTouch(event))
        .onClick(() => this.onActivate())
      } else {
        Button() {
          this.RowContent()
        }
        .id(this.rowId)
        .type(ButtonType.Normal).width('100%').height(this.rowHeight())
        .padding(0).borderRadius(14).backgroundColor(Color.Transparent).stateEffect(true)
        .onAreaChange((_, area: Area) => this.onRowArea(area))
        .onTouch((event: TouchEvent) => this.onRowTouch(event))
        .onClick(() => this.onActivate())
      }

      if (this.showDivider) {
        if (this.compact()) {
          ContentDivider({ startInset: 16, endInset: 10 })
        } else {
          ContentDivider({ startInset: 10, endInset: 8, lineColor: $r('sys.color.comp_divider') })
        }
      }
    }
    .width('100%')
  }
}

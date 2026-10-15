import { HeaderStyle } from '../ui/HeaderStyle'
import { TaskPanelStyle } from '../ui/TaskPanelStyle'

@Builder
function EmptyTaskPanelSlot(): void { Column() {}.width(0).height(0) }

/** Layout owns presentation only. Slots retain the caller's data source and lifecycle. */
@Component
export struct TaskPanel {
  @Prop title: string = ''
  @Prop idPrefix: string = 'task-panel'
  @Prop fillHeight: boolean = true
  @Prop safeTop: number = 0
  @Prop hasFooter: boolean = false
  @Prop closeEnabled: boolean = true
  @Prop showAuxiliary: boolean = false
  @Prop auxiliaryEnabled: boolean = true
  @Prop auxiliaryIcon: Resource = $r('sys.symbol.folder_badge_plus')
  @Prop auxiliaryLabel: string = ''
  onClose: () => void = () => {}
  onAuxiliary: () => void = () => {}
  @BuilderParam content: () => void = EmptyTaskPanelSlot
  @BuilderParam footer: () => void = EmptyTaskPanelSlot

  build() {
    Column() {
      Column() {
        TaskPanelHeader({ title: this.title, idPrefix: this.idPrefix,
          closeEnabled: this.closeEnabled, showAuxiliary: this.showAuxiliary,
          auxiliaryEnabled: this.auxiliaryEnabled, auxiliaryIcon: this.auxiliaryIcon,
          auxiliaryLabel: this.auxiliaryLabel, onClose: this.onClose, onAuxiliary: this.onAuxiliary })
        Column() { this.content() }
          .width('100%').layoutWeight(this.fillHeight ? 1 : 0)
          .padding({ left: TaskPanelStyle.inset, right: TaskPanelStyle.inset })
          .alignItems(HorizontalAlign.Start)
        if (this.hasFooter) { this.footer() }
      }
      .width('100%').layoutWeight(this.fillHeight ? 1 : 0)
      .backgroundColor($r('app.color.task_panel_background'))
      .borderRadius({ topLeft: TaskPanelStyle.corner, topRight: TaskPanelStyle.corner })
      .clip(true)
      .id(this.idPrefix + '-panel')
    }
    .width('100%').height(this.fillHeight ? '100%' : undefined)
    .padding({ top: this.fillHeight ? this.safeTop + HeaderStyle.topPadding : 0 })
    .backgroundColor(Color.Transparent)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

@Component
export struct TaskPanelHeader {
  @Prop title: string = ''
  @Prop idPrefix: string = 'task-panel'
  @Prop closeEnabled: boolean = true
  @Prop showAuxiliary: boolean = false
  @Prop auxiliaryEnabled: boolean = true
  @Prop auxiliaryIcon: Resource = $r('sys.symbol.folder_badge_plus')
  @Prop auxiliaryLabel: string = ''
  onClose: () => void = () => {}
  onAuxiliary: () => void = () => {}

  build() {
    Row({ space: HeaderStyle.gap }) {
      Text(this.title).fontSize(HeaderStyle.titleSize).fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary')).textAlign(TextAlign.Start)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1).id(this.idPrefix + '-title')
      if (this.showAuxiliary) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.auxiliaryIcon).fontSize(HeaderStyle.iconSize)
            .fontColor([$r('sys.color.icon_primary')])
        }
        .width(HeaderStyle.controlHeight).height(HeaderStyle.controlHeight)
        .backgroundColor($r('app.color.task_panel_control_background'))
        .enabled(this.auxiliaryEnabled).accessibilityText(this.auxiliaryLabel)
        .onClick(() => this.onAuxiliary()).id(this.idPrefix + '-auxiliary')
      }
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(HeaderStyle.iconSize)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(HeaderStyle.controlHeight).height(HeaderStyle.controlHeight)
      .backgroundColor($r('app.color.task_panel_control_background'))
      .enabled(this.closeEnabled).accessibilityText('关闭' + this.title)
      .onClick(() => this.onClose()).id(this.idPrefix + '-close')
    }
    .width('100%').height(TaskPanelStyle.headerHeight)
    .padding({ left: TaskPanelStyle.inset, right: TaskPanelStyle.inset })
  }
}

@Component
export struct TaskPanelSection {
  @Prop fillHeight: boolean = false
  @Prop paddingSize: number = TaskPanelStyle.inset
  @BuilderParam content: () => void = EmptyTaskPanelSlot

  build() {
    Column() { this.content() }
      .width('100%').height(this.fillHeight ? '100%' : undefined)
      .padding(this.paddingSize).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.task_panel_content_background'))
      .borderRadius(TaskPanelStyle.sectionCorner).clip(true)
  }
}

@Component
export struct TaskPanelFooter {
  @Prop label: string = ''
  @Prop actionId: string = 'task-panel-action'
  @Prop actionEnabled: boolean = true
  @Prop busy: boolean = false
  @Prop summaryTitle: string = ''
  @Prop summaryValue: string = ''
  @Prop safeBottom: number = 0
  onAction: () => void = () => {}

  build() {
    Column({ space: TaskPanelStyle.sectionGap }) {
      if (this.summaryValue.length > 0) {
        Column({ space: 4 }) {
          Text(this.summaryTitle).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.summaryValue).fontSize(12).fontColor($r('sys.color.font_secondary'))
            .maxLines(2).wordBreak(WordBreak.BREAK_ALL)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).id(this.actionId + '-destination')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 8 }) {
          if (this.busy) {
            LoadingProgress().width(16).height(16).color($r('sys.color.font_on_primary'))
          }
          Text(this.label).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_on_primary')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').justifyContent(FlexAlign.Center)
      }
      .width('100%').height(TaskPanelStyle.actionHeight)
      .backgroundColor($r('sys.color.comp_background_emphasize'))
      .enabled(this.actionEnabled && !this.busy).onClick(() => this.onAction()).id(this.actionId)
    }
    .width('100%').padding({ left: TaskPanelStyle.inset, right: TaskPanelStyle.inset,
      top: TaskPanelStyle.footerPadding, bottom: this.safeBottom + TaskPanelStyle.footerPadding })
    .backgroundColor($r('app.color.task_panel_background'))
  }
}

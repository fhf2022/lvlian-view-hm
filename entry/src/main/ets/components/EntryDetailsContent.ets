/** Shared content of the native centred details dialog. System colour resources
 * keep title and metadata eligible for the same glass inversion as menu text.
 */
@Component
export struct EntryDetailsContent {
  @Prop title: string = ''
  @Prop message: string = ''
  @Prop maxContentHeight: number = 400
  onConfirm: () => void = () => {}

  build() {
    Column() {
      Text(this.title).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary')).textAlign(TextAlign.Center)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Scroll() {
        Text(this.message).fontSize(16).fontColor($r('sys.color.font_primary'))
          .textAlign(TextAlign.Center).width('100%')
      }
      .width('100%').height('auto').constraintSize({ maxHeight: this.maxContentHeight })
      .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None).margin({ top: 20, bottom: 8 })
      Button('确定').id('entry-details-confirm').type(ButtonType.Normal)
        .width('100%').height(48).borderRadius(14).padding(0)
        .backgroundColor(Color.Transparent).fontSize(16).fontColor($r('sys.color.font_emphasize'))
        .onClick(() => this.onConfirm())
    }
    .id('entry-details-content')
    .width('100%').padding({ left: 24, right: 24, top: 16, bottom: 8 })
  }
}

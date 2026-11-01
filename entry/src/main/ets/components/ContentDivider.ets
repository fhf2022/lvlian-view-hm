/** One horizontal separator, inset to the content rather than the leading icon. */
@Component
export struct ContentDivider {
  @Prop startInset: number = 0
  @Prop endInset: number = 0
  @Prop verticalInset: number = 0
  @Prop lineColor: ResourceColor = $r('app.color.divider')

  build() {
    Row() {
      Divider().width('100%').strokeWidth(0.5).color(this.lineColor)
    }
    .width('100%')
    .padding({ left: this.startInset, right: this.endInset,
      top: this.verticalInset, bottom: this.verticalInset })
    .hitTestBehavior(HitTestMode.None)
  }
}

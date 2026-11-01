import { FileRowStyle } from '../ui/FileRowStyle'
import { ContentDivider } from './ContentDivider'

@Builder
function EmptyFileListSlot(): void { Blank().width(0).height(0) }

/** Presentation only. Owners retain item identity, loading, gestures and navigation. */
@Component
export struct FileListRow {
  @Prop title: string = ''
  @Prop info: string = ''
  @Prop titleColor: ResourceColor = $r('app.color.text_primary')
  @Prop infoColor: ResourceColor = $r('app.color.text_muted')
  @Prop startInset: number = FileRowStyle.horizontalPadding
  @Prop endInset: number = FileRowStyle.horizontalPadding
  @Prop leadingGap: number = FileRowStyle.leadingGap
  @Prop showDivider: boolean = false
  @BuilderParam leading: () => void = EmptyFileListSlot
  @BuilderParam trailing: () => void = EmptyFileListSlot

  build() {
    Column() {
      Row() {
        Stack() { this.leading() }
          .width(FileRowStyle.leadingWidth).height(FileRowStyle.leadingHeight)
          .margin({ right: this.leadingGap })
        Column() {
          Text(this.title).fontSize(FileRowStyle.titleSize).fontColor(this.titleColor)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.info.length > 0) {
            Text(this.info).fontSize(FileRowStyle.infoSize).fontColor(this.infoColor)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: FileRowStyle.textGap })
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        this.trailing()
      }
      .width('100%').alignItems(VerticalAlign.Center)
      .padding({ left: this.startInset, right: this.endInset,
        top: FileRowStyle.verticalPadding, bottom: FileRowStyle.verticalPadding })
      if (this.showDivider) {
        ContentDivider({ startInset: this.startInset + FileRowStyle.leadingWidth + this.leadingGap,
          endInset: this.endInset })
      }
    }.width('100%')
  }
}

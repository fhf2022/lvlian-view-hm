import { DirectorySizeQuery } from '../ugreen/DirectorySizeQuery'

export class EntryDetailsData {
  type: string = ''
  size: string = ''
  modifiedTime: string = ''
  path: string = ''
  items: string = ''
}

/** Shared content of the native centred details dialog. System colour resources
 * keep title and metadata eligible for the same glass inversion as menu text.
 */
@Component
export struct EntryDetailsContent {
  @Prop title: string = ''
  @Prop data: EntryDetailsData = new EntryDetailsData()
  @Prop maxContentHeight: number = 400
  createSizeQuery: (() => DirectorySizeQuery) | null = null
  formatSize: (size: number) => string = (size: number): string => size.toString()
  onConfirm: () => void = () => {}
  @State private directorySize: string = '计算中'
  private sizeQuery: DirectorySizeQuery | null = null

  aboutToAppear(): void {
    if (this.createSizeQuery === null) { return }
    try {
      this.sizeQuery = this.createSizeQuery()
      this.sizeQuery.start((size: number | null): void => {
        this.directorySize = size === null ? '暂时无法获取' : this.formatSize(size)
      })
    } catch (_) { this.directorySize = '暂时无法获取' }
  }

  aboutToDisappear(): void {
    this.sizeQuery?.stop()
    this.sizeQuery = null
  }

  private message(): string {
    const lines = ['类型：' + this.data.type]
    if (this.data.items.length > 0) { lines.push('项目：' + this.data.items) }
    lines.push('大小：' + (this.createSizeQuery === null ? this.data.size : this.directorySize),
      '修改时间：' + this.data.modifiedTime, '位置：' + this.data.path)
    return lines.join('\n')
  }

  build() {
    Column() {
      Text(this.title).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary')).textAlign(TextAlign.Center)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Scroll() {
        Text(this.message()).fontSize(16).fontColor($r('sys.color.font_primary'))
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

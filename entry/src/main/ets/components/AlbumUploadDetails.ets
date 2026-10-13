import { AlbumUploadItem } from '../upload/AlbumUploadModel'
import { AlbumUploadManager } from '../upload/AlbumUploadManager'

@Component
export struct AlbumUploadDetails {
  manager: AlbumUploadManager = new AlbumUploadManager()
  @Prop batchId: string = ''
  @Prop albumName: string = ''
  @State items: AlbumUploadItem[] = []
  @State pageOffset: number = 0
  @State failures: boolean = false
  @State loading: boolean = false
  @State error: string = ''
  private generation: number = 0
  aboutToAppear(): void { this.load(0) }
  aboutToDisappear(): void { this.generation++ }
  private async load(offset: number): Promise<void> {
    const generation = ++this.generation
    this.loading = true
    try {
      const items = await this.manager.details(this.batchId, offset, this.failures)
      if (generation !== this.generation) { return }
      this.items = items; this.pageOffset = offset; this.error = ''
    } catch (error) { if (generation === this.generation) { this.error = '读取任务明细失败，请刷新' } }
    finally { if (generation === this.generation) { this.loading = false } }
  }
  private status(item: AlbumUploadItem): string {
    if (item.state === 'uploaded') { return '已上传' }
    if (item.state === 'skipped') { return '已有同名同大小图片，已跳过' }
    if (item.state === 'failed') { return item.error }
    return item.state === 'active' ? '正在上传' : '等待上传'
  }
  build() {
    Column({ space: 12 }) {
      Text(this.albumName + ' · 上传明细').fontSize(20).fontWeight(FontWeight.Medium).width('100%').maxLines(2)
      Row({ space: 12 }) {
        Button(this.failures ? '查看全部' : '只看失败').fontSize(14).enabled(!this.loading)
          .onClick(() => { this.failures = !this.failures; this.load(0) })
        Button('刷新').fontSize(14).enabled(!this.loading).onClick(() => this.load(this.pageOffset))
      }
      if (this.error) { Text(this.error).fontSize(13) }
      List({ space: 4 }) {
        ForEach(this.items, (item: AlbumUploadItem) => {
          ListItem() {
            Column({ space: 4 }) {
              Text(item.name).fontSize(15).width('100%').maxLines(2)
              Text(this.status(item)).fontSize(12).fontColor(item.state === 'failed' ? '#B94739' : $r('app.color.text_muted')).width('100%').maxLines(3)
            }.width('100%').padding(10).alignItems(HorizontalAlign.Start)
          }
        }, (item: AlbumUploadItem): string => item.id)
      }.layoutWeight(1).width('100%')
      if (!this.loading && this.items.length === 0) { Text(this.failures ? '暂无失败项' : '暂无图片记录').fontSize(14) }
      Row({ space: 12 }) {
        Button('上一页').fontSize(14).enabled(!this.loading && this.pageOffset > 0).onClick(() => this.load(Math.max(0, this.pageOffset - 100)))
        Text((Math.floor(this.pageOffset / 100) + 1).toString()).fontSize(14)
        Button('下一页').fontSize(14).enabled(!this.loading && this.items.length === 100).onClick(() => this.load(this.pageOffset + 100))
      }
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 12, bottom: 28 })
  }
}

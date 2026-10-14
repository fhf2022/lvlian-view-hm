import { CapsuleSegmentButtonV2, LengthMetrics, SegmentButtonV2Items } from '@kit.ArkUI'
import { AlbumUploadItem, AlbumUploadState } from '../upload/AlbumUploadModel'
import { AlbumUploadManager } from '../upload/AlbumUploadManager'
import { TransferTaskListRow } from './TransferTaskListRow'

@Component
export struct AlbumUploadDetails {
  manager: AlbumUploadManager = new AlbumUploadManager()
  @Prop batchId: string = ''
  @Prop albumName: string = ''
  @Prop total: number = 0
  @Prop failedCount: number = 0
  @Prop batchState: AlbumUploadState = 'paused'
  @Prop currentName: string = ''
  @Prop currentBytes: number = 0
  @Prop currentSize: number = 0
  @Prop @Watch('onRevisionChanged') revision: string = ''
  @State items: AlbumUploadItem[] = []
  @State pageOffset: number = 0
  @State failures: boolean = false
  @State loading: boolean = false
  @State error: string = ''
  private readonly filters: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '全部' }, { text: '失败' }])
  private readonly scroller: Scroller = new Scroller()
  private generation: number = 0
  private visible: boolean = false
  private reloadPending: boolean = false
  private renderedFailures: boolean = false

  aboutToAppear(): void { this.visible = true; this.load(0) }
  aboutToDisappear(): void { this.visible = false; this.reloadPending = false; this.generation++ }

  private onRevisionChanged(): void {
    if (!this.visible) { return }
    // Refresh the page when items change, never for individual byte progress updates.
    if (this.loading) { this.reloadPending = true; return }
    this.load(this.pageOffset)
  }

  private itemCount(): number { return this.failures ? this.failedCount : this.total }
  private hasNext(): boolean { return this.pageOffset + 100 < this.itemCount() }

  private async load(offset: number): Promise<void> {
    const generation = ++this.generation
    const failures = this.failures
    const pageOffset = Math.min(offset, Math.floor(Math.max(0, this.itemCount() - 1) / 100) * 100)
    this.loading = true
    try {
      const items = await this.manager.details(this.batchId, pageOffset, failures)
      if (generation !== this.generation) { return }
      const resetScroll = this.pageOffset !== pageOffset || this.renderedFailures !== failures
      this.items = items; this.pageOffset = pageOffset; this.renderedFailures = failures; this.error = ''
      if (resetScroll) { this.scroller.scrollTo({ xOffset: 0, yOffset: 0 }) }
    } catch (_) {
      if (generation === this.generation) { this.error = '读取明细失败' }
    } finally {
      if (generation === this.generation) {
        this.loading = false
        if (this.visible && this.reloadPending) { this.reloadPending = false; this.load(this.pageOffset) }
      }
    }
  }

  private isCurrent(item: AlbumUploadItem): boolean {
    return item.state === 'active' && item.name === this.currentName
  }

  private status(item: AlbumUploadItem): string {
    if (item.state === 'uploaded') { return '已上传' }
    if (item.state === 'skipped') { return '已跳过' }
    if (item.state === 'failed') { return '失败 · ' + (item.error || '上传失败') }
    if (this.batchState === 'paused') { return '已暂停' }
    if (this.batchState === 'waiting_wifi') { return '等待 WiFi' }
    if (this.batchState === 'waiting_server') { return '等待 NAS 连接' }
    if (this.batchState === 'waiting_foreground') { return '等待继续' }
    return this.isCurrent(item) && this.batchState === 'running' ? '正在上传' : '等待上传'
  }

  private sizeText(size: number): string {
    if (size <= 0) { return '未知大小' }
    if (size < 1024) { return size.toString() + ' B' }
    if (size < 1024 * 1024) { return (size / 1024).toFixed(1) + ' KB' }
    if (size < 1024 * 1024 * 1024) { return (size / (1024 * 1024)).toFixed(1) + ' MB' }
    return (size / (1024 * 1024 * 1024)).toFixed(1) + ' GB'
  }

  private progress(item: AlbumUploadItem): number {
    if (item.state === 'uploaded' || item.state === 'skipped') { return 100 }
    if (!this.isCurrent(item) || this.currentSize <= 0) { return 0 }
    return Math.min(99, Math.max(0, this.currentBytes / this.currentSize * 100))
  }

  private async showFailure(item: AlbumUploadItem): Promise<void> {
    if (item.state !== 'failed') { return }
    try {
      await this.getUIContext().getPromptAction().showDialog({ title: item.name,
        message: item.error || '上传失败', buttons: [{ text: '关闭', color: '#2E6BFF' }] })
    } catch (_) {}
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text(this.albumName + ' · 明细')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .id('album-details-title')
        CapsuleSegmentButtonV2({ items: this.filters, selectedIndex: this.failures ? 1 : 0,
          $selectedIndex: (index: number): void => {
            const failures = index === 1
            if (this.loading || this.failures === failures) { return }
            this.failures = failures; this.load(0)
          },
          itemFontSize: LengthMetrics.fp(13), itemSelectedFontSize: LengthMetrics.fp(13),
          buttonMinHeight: LengthMetrics.vp(36), itemMinHeight: LengthMetrics.vp(32) })
          .width(124)
          .enabled(!this.loading)
          .id('album-details-filter')
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .enabled(!this.loading)
        .accessibilityText('刷新明细')
        .id('album-details-refresh')
        .onClick(() => this.load(this.pageOffset))
      }
      // Reserve the native sheet close button's space on the right.
      .width('100%')
      .padding({ left: 16, right: 64, top: 12, bottom: 12 })
      if (this.error.length > 0) {
        Text(this.error).fontSize(13).fontColor($r('app.color.album_upload_error'))
          .width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }
      Stack() {
        List({ space: 0, scroller: this.scroller }) {
          ForEach(this.items, (item: AlbumUploadItem) => {
            ListItem() {
              TransferTaskListRow({ title: item.name, info: this.sizeText(item.size) + ' · ' + this.status(item),
                infoColor: item.state === 'failed' ? $r('app.color.album_upload_error') : $r('app.color.text_muted'),
                progress: this.progress(item),
                loading: this.isCurrent(item) && this.batchState === 'running' && this.currentSize <= 0 })
            }
            .width('100%')
            .id('album-details-item:' + item.id)
            .onClick(() => this.showFailure(item))
          }, (item: AlbumUploadItem): string => item.id + ':' + item.state + ':' + item.error)
        }
        .width('100%')
        .height('100%')
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        if (this.items.length === 0) {
          if (this.loading) {
            LoadingProgress().width(30).height(30).color('#2E6BFF')
          } else if (this.error.length === 0) {
            Text(this.failures ? '暂无失败项' : '暂无图片记录')
              .fontSize(14).fontColor($r('app.color.text_muted'))
              .id('album-details-empty')
          }
        }
      }.layoutWeight(1).width('100%')
      if (this.pageOffset > 0 || this.hasNext()) {
        Row({ space: 16 }) {
          Button('上一页').fontSize(14).height(36).backgroundColor(Color.Transparent).fontColor('#2E6BFF')
            .enabled(!this.loading && this.pageOffset > 0)
            .onClick(() => this.load(this.pageOffset - 100))
          Text((Math.floor(this.pageOffset / 100) + 1).toString()).fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Button('下一页').fontSize(14).height(36).backgroundColor(Color.Transparent).fontColor('#2E6BFF')
            .enabled(!this.loading && this.hasNext())
            .onClick(() => this.load(this.pageOffset + 100))
        }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 8 })
      }
    }.width('100%').height('100%').padding({ bottom: 28 })
  }
}

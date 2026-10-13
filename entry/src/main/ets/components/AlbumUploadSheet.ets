import { common } from '@kit.AbilityKit'
import { LengthMetrics } from '@kit.ArkUI'
import { LocalAlbumSource } from '../upload/LocalAlbumSource'
import { LocalImageAlbum } from '../upload/AlbumUploadModel'

@Component
export struct AlbumUploadSheet {
  @Link visible: boolean
  @Prop album: LocalImageAlbum = new LocalImageAlbum()
  @Prop destination: string = ''
  @Prop contentMaxHeight: number = 480
  onReselect: () => void = () => {}
  onStart: (album: LocalImageAlbum) => Promise<void> = async () => {}
  @State selected: LocalImageAlbum | null = null
  @State loading: boolean = false
  @State starting: boolean = false
  @State error: string = ''
  @State showRules: boolean = false
  private generation: number = 0
  aboutToAppear(): void { this.selected = this.album }
  aboutToDisappear(): void { this.generation++ }
  private async select(uri: string, name: string): Promise<void> {
    if (this.loading || this.starting) { return }
    const generation = ++this.generation
    this.loading = true; this.error = ''
    try {
      const source = new LocalAlbumSource(getContext(this) as common.UIAbilityContext)
      await source.requestPermission()
      if (generation !== this.generation) { return }
      const album = await source.selectedAlbum(uri, name)
      if (generation === this.generation) { this.selected = album }
    } catch (error) {
      if (generation === this.generation) { this.error = (error as Error).message || '本地图片文件夹读取失败' }
    } finally { if (generation === this.generation) { this.loading = false } }
  }
  private async start(): Promise<void> {
    const album = this.selected
    if (!album || this.starting) { return }
    this.starting = true; this.error = ''
    try { await this.onStart(album); this.visible = false }
    catch (error) { this.error = (error as Error).message || '创建上传任务失败' }
    finally { this.starting = false }
  }
  @Builder
  AlbumSummary() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('本地相册').fontSize(12).fontColor($r('sys.color.font_secondary'))
          Text(this.selected?.name || '未选择相册').fontSize(19).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('更换').fontSize(14).height(40).padding({ left: 12, right: 12 })
          .fontColor($r('sys.color.font_secondary')).backgroundColor(Color.Transparent)
          .enabled(!this.starting && !this.loading).accessibilityText('重新选择相册')
          .onClick(() => { this.generation++; this.onReselect() }).id('album-upload-reselect')
      }.width('100%')
      Row({ space: 12 }) {
        Text() {
          Span((this.selected?.localCount || 0).toString()).fontSize(28).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Span(' 张可上传').fontSize(14).fontColor($r('sys.color.font_secondary'))
        }.layoutWeight(1).id('album-upload-count')
          .accessibilityText('可上传 ' + (this.selected?.localCount || 0).toString() + ' 张图片')
        Button(this.loading ? '读取中…' : '刷新数量').fontSize(13).height(36).padding({ left: 12, right: 12 })
          .fontColor($r('sys.color.font_secondary')).backgroundColor($r('sys.color.comp_background_tertiary'))
          .enabled(!this.loading && !this.starting)
          .onClick(() => { if (this.selected) { this.select(this.selected.uri, this.selected.name) } })
          .id('album-upload-refresh')
      }.width('100%')
      Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ top: 2, bottom: 2 })
      Column({ space: 4 }) {
        Text('NAS 目标').fontSize(12).fontColor($r('sys.color.font_secondary'))
        Text(this.destination).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
          .maxLines(3).wordBreak(WordBreak.BREAK_ALL).textOverflow({ overflow: TextOverflow.Ellipsis })
          .id('album-upload-destination')
      }.width('100%').alignItems(HorizontalAlign.Start)
      Text('云端照片请先在系统图库缓存，再回来刷新数量。')
        .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%').margin({ top: 2 })
        .id('album-upload-cache-hint')
      if (this.selected && this.selected.movingCount > 0) {
        Text(this.selected.movingCount.toString() + ' 张动态照片仅上传静态图片。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_card')).borderRadius(16)
  }

  @Builder
  UploadOptions() {
    Column({ space: 8 }) {
      Text('仅 Wi-Fi 上传。后台保护开启后可锁屏，通知中心可查看总进度；完成后通知自动收起。')
        .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ top: 4 })
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Text('同名同大小跳过，冲突保留两份。').fontSize(13)
            .fontColor($r('sys.color.font_secondary')).layoutWeight(1).textAlign(TextAlign.Start)
          SymbolGlyph(this.showRules ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(14).fontColor([$r('sys.color.icon_secondary')])
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 40 }).padding({ top: 4, bottom: 4 })
        .backgroundColor(Color.Transparent).accessibilityText(this.showRules ? '收起上传规则' : '展开上传规则')
        .onClick(() => { this.showRules = !this.showRules })
        .id('album-upload-rules')
      if (this.showRules) {
        Text('以点击上传时的图片清单为准。同名但大小不同会保留两份；原图被修改或删除会列为失败项。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%').id('album-upload-rules-detail')
      }
    }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })
      .alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.surface_card')).borderRadius(16)
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('上传相册').fontSize(21).fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary')).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([$r('sys.color.icon_secondary')])
        }.width(40).height(40).backgroundColor($r('app.color.surface_card'))
          .accessibilityText('关闭上传确认').onClick(() => { this.visible = false }).id('album-upload-close')
      }.width('100%').constraintSize({ minHeight: 44 })
      Scroll() {
        Column({ space: 12 }) {
          this.AlbumSummary()
          this.UploadOptions()
          if (this.error) {
            Text(this.error).fontSize(13).fontColor($r('app.color.album_upload_error'))
              .width('100%').id('album-upload-error')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ maxHeight: this.contentMaxHeight }).align(Alignment.TopStart)
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(16) })
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      Button(this.starting ? '正在准备…' : '开始上传').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary')).backgroundColor($r('sys.color.comp_background_emphasize'))
        .width('100%').height(48).enabled(!this.starting && !this.loading && (this.selected?.localCount || 0) > 0)
        .onClick(() => this.start()).id('album-upload-start')
    }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 20 })
      .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
  }
}

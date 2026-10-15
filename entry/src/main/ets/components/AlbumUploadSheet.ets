import { common } from '@kit.AbilityKit'
import { LengthMetrics } from '@kit.ArkUI'
import { LocalAlbumSource } from '../upload/LocalAlbumSource'
import { LocalImageAlbum } from '../upload/AlbumUploadModel'
import { TaskPanel, TaskPanelFooter, TaskPanelSection } from './TaskPanel'
import { TaskPanelStyle } from '../ui/TaskPanelStyle'
import { FileRowStyle } from '../ui/FileRowStyle'

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
  @Prop starting: boolean = false
  private startPending: boolean = false
  @State error: string = ''
  private generation: number = 0
  aboutToAppear(): void { this.selected = this.album }
  aboutToDisappear(): void { this.generation++ }
  private async select(uri: string, name: string): Promise<void> {
    if (this.loading || this.starting) { return }
    const generation = ++this.generation
    this.loading = true; this.error = ''
    try {
      const source = new LocalAlbumSource(getContext(this) as common.UIAbilityContext)
      await source.requestPermission(true)
      if (generation !== this.generation) { return }
      const album = await source.selectedAlbum(uri, name)
      if (generation === this.generation) { this.selected = album }
    } catch (error) {
      if (generation === this.generation) { this.error = (error as Error).message || '本地图片文件夹读取失败' }
    } finally { if (generation === this.generation) { this.loading = false } }
  }
  private async start(): Promise<void> {
    const album = this.selected
    if (!album || this.starting || this.startPending) { return }
    const generation = ++this.generation
    this.startPending = true; this.error = ''
    try {
      await this.onStart(album)
      if (generation === this.generation && this.visible) { this.visible = false }
    } catch (error) {
      if (generation === this.generation && this.visible) {
        this.error = (error as Error).message || '创建上传任务失败'
      }
    } finally { this.startPending = false }
  }

  @Builder
  AlbumSummary() {
    TaskPanelSection() {
      Column({ space: FileRowStyle.leadingGap }) {
        Row({ space: FileRowStyle.leadingGap }) {
          Column({ space: FileRowStyle.textGap }) {
            Text('本地相册').fontSize(FileRowStyle.infoSize).fontColor($r('sys.color.font_secondary'))
            Text(this.selected?.name || '未选择相册').fontSize(FileRowStyle.titleSize).fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('更换').fontSize(14).height(40).padding({ left: 12, right: 12 })
            .fontColor($r('sys.color.font_secondary')).backgroundColor(Color.Transparent)
            .enabled(!this.starting && !this.loading).accessibilityText('重新选择相册')
            .onClick(() => { this.generation++; this.onReselect() }).id('album-upload-reselect')
        }.width('100%')
        Row({ space: FileRowStyle.leadingGap }) {
          Text() {
            Span((this.selected?.localCount || 0).toString()).fontSize(FileRowStyle.titleSize).fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
            Span(' 张可上传').fontSize(14).fontColor($r('sys.color.font_secondary'))
          }.layoutWeight(1).id('album-upload-count')
            .accessibilityText('可上传 ' + (this.selected?.localCount || 0).toString() + ' 张图片')
          Button(this.loading ? '读取中…' : '刷新数量').fontSize(13).height(40).padding({ left: 12, right: 12 })
            .fontColor($r('sys.color.font_secondary')).backgroundColor($r('sys.color.comp_background_tertiary'))
            .enabled(!this.loading && !this.starting)
            .onClick(() => { if (this.selected) { this.select(this.selected.uri, this.selected.name) } })
            .id('album-upload-refresh')
        }.width('100%')
        Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ top: 2, bottom: 2 })
        Column({ space: FileRowStyle.textGap }) {
          Text('NAS 目标').fontSize(FileRowStyle.infoSize).fontColor($r('sys.color.font_secondary'))
          Text(this.destination).fontSize(14).fontColor($r('sys.color.font_primary')).width('100%')
            .maxLines(3).wordBreak(WordBreak.BREAK_ALL).textOverflow({ overflow: TextOverflow.Ellipsis })
            .id('album-upload-destination')
        }.width('100%').alignItems(HorizontalAlign.Start)
        Text('云端照片先在图库缓存，再刷新数量。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%').margin({ top: 2 })
          .id('album-upload-cache-hint')
        if (this.selected && this.selected.movingCount > 0) {
          Text(this.selected.movingCount.toString() + ' 张动态照片仅上传静态图片。')
            .fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  ConfirmationContent(): void {
    Scroll() {
      Column({ space: TaskPanelStyle.sectionGap }) {
        this.AlbumSummary()
        Text('仅 Wi-Fi · 同名同大小跳过，冲突保留两份')
          .fontSize(FileRowStyle.infoSize).fontColor($r('sys.color.font_secondary')).width('100%')
          .id('album-upload-policy')
        if (this.error) {
          Text(this.error).fontSize(13).fontColor($r('app.color.album_upload_error'))
            .width('100%').id('album-upload-error')
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').constraintSize({ maxHeight: this.contentMaxHeight }).align(Alignment.TopStart)
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(16) })
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
  }

  @Builder
  ConfirmationFooter(): void {
    TaskPanelFooter({ label: this.starting ? '正在准备…' : '开始上传', actionId: 'album-upload-start',
      busy: this.starting, actionEnabled: !this.loading && (this.selected?.localCount || 0) > 0,
      onAction: (): void => { this.start() } })
  }

  build() {
    TaskPanel({ title: '上传相册', idPrefix: 'album-upload', fillHeight: false, hasFooter: true,
      closeEnabled: !this.starting, onClose: (): void => { this.generation++; this.visible = false },
      content: (): void => { this.ConfirmationContent() },
      footer: (): void => { this.ConfirmationFooter() } })
  }
}

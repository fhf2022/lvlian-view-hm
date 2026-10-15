import { common } from '@kit.AbilityKit'
import { AlbumPickerComponent, AlbumPickerOptions, AlbumInfo, photoAccessHelper } from '@kit.MediaLibraryKit'
import { LocalAlbumSource, LocalAlbumPermissionError } from '../upload/LocalAlbumSource'
import { LocalImageAlbum } from '../upload/AlbumUploadModel'
import { FileRowStyle } from '../ui/FileRowStyle'
import { TaskPanel, TaskPanelSection } from './TaskPanel'

/** Only the system album list is shown here; upload options belong to the next page. */
@Component
export struct AlbumUploadPicker {
  @Link visible: boolean
  @Prop safeTop: number = 0
  @Prop safeBottom: number = 0
  onSelected: (album: LocalImageAlbum) => void = () => {}
  @State loading: boolean = false
  @State error: string = ''
  @State permissionRequired: boolean = false
  private pendingInfo: AlbumInfo | null = null
  private generation: number = 0
  private options: AlbumPickerOptions = { filterType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
    fontSize: FileRowStyle.titleSize }

  aboutToDisappear(): void { this.generation++ }

  private async select(info: AlbumInfo): Promise<void> {
    if (this.loading || !this.visible) { return }
    if (!info.uri) { this.error = '此相册暂不可读取，请选择一个具体图片文件夹'; return }
    this.pendingInfo = info
    this.permissionRequired = false
    const generation = ++this.generation
    this.loading = true
    this.error = ''
    try {
      const source = new LocalAlbumSource(getContext(this) as common.UIAbilityContext)
      await source.requestPermission(true)
      if (generation !== this.generation || !this.visible) { return }
      const album = await source.selectedAlbum(info.uri, info.albumName || '')
      if (generation === this.generation && this.visible) { this.onSelected(album) }
    } catch (error) {
      if (generation === this.generation && this.visible) {
        this.permissionRequired = error instanceof LocalAlbumPermissionError
        this.error = (error as Error).message || '本地图片文件夹读取失败'
      }
    } finally {
      if (generation === this.generation) { this.loading = false }
    }
  }

  @Builder
  PickerContent(): void {
    Column() {
      if (this.loading || this.error) {
        Row({ space: 8 }) {
          Text(this.loading ? '读取中…' : this.error)
            .fontSize(13).fontColor(this.error ? $r('app.color.album_upload_error') : $r('sys.color.font_secondary'))
            .layoutWeight(1).id('album-upload-picker-status')
          if (this.permissionRequired && !this.loading) {
            Button('允许读取图片').fontSize(13).height(40).padding({ left: 12, right: 12 })
              .fontColor($r('sys.color.font_primary'))
              .backgroundColor($r('app.color.task_panel_control_background'))
              .onClick(() => { if (this.pendingInfo) { this.select(this.pendingInfo) } })
              .id('album-upload-picker-permission')
          }
        }.width('100%').padding({ top: 8, bottom: 12 })
      }
      Column() {
        TaskPanelSection({ fillHeight: true, paddingSize: 0 }) {
          Stack({ alignContent: Alignment.Bottom }) {
            AlbumPickerComponent({ albumPickerOptions: this.options,
              onAlbumClick: (info: AlbumInfo): boolean => { this.select(info); return true }
            }).width('100%').height('100%').id('album-upload-system-picker')
            // Visual edge only; native album gestures continue through the navigation area.
            Column() {}.width('100%').height(Math.min(20, this.safeBottom))
              .linearGradient({ direction: GradientDirection.Bottom,
                colors: [[$r('app.color.album_picker_fade_start'), 0],
                  [$r('app.color.task_panel_content_background'), 1]] })
              .hitTestBehavior(HitTestMode.None)
          }.width('100%').height('100%')
        }
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
  }

  build() {
    TaskPanel({ title: '我的相册', idPrefix: 'album-upload-picker', safeTop: this.safeTop,
      onClose: (): void => { this.generation++; this.visible = false },
      content: (): void => { this.PickerContent() } })
  }
}

import { common } from '@kit.AbilityKit'
import { AlbumPickerComponent, AlbumPickerOptions, AlbumInfo, photoAccessHelper } from '@kit.MediaLibraryKit'
import { LocalAlbumSource } from '../upload/LocalAlbumSource'
import { LocalImageAlbum } from '../upload/AlbumUploadModel'

/** Only the system album list is shown here; upload options belong to the next page. */
@Component
export struct AlbumUploadPicker {
  @Link visible: boolean
  @Prop safeTop: number = 0
  @Prop safeBottom: number = 0
  @Prop viewportWidth: number = 376
  onSelected: (album: LocalImageAlbum) => void = () => {}
  @State loading: boolean = false
  @State error: string = ''
  private generation: number = 0
  private options: AlbumPickerOptions = { filterType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE }

  aboutToDisappear(): void { this.generation++ }

  private async select(info: AlbumInfo): Promise<void> {
    if (this.loading || !this.visible) { return }
    if (!info.uri) { this.error = '此相册暂不可读取，请选择一个具体图片文件夹'; return }
    const generation = ++this.generation
    this.loading = true
    this.error = ''
    try {
      const source = new LocalAlbumSource(getContext(this) as common.UIAbilityContext)
      await source.requestPermission()
      if (generation !== this.generation || !this.visible) { return }
      const album = await source.selectedAlbum(info.uri, info.albumName || '')
      if (generation === this.generation && this.visible) { this.onSelected(album) }
    } catch (error) {
      if (generation === this.generation && this.visible) {
        this.error = (error as Error).message || '本地图片文件夹读取失败'
      }
    } finally {
      if (generation === this.generation) { this.loading = false }
    }
  }

  build() {
    Column() {
      Column() {
        // Keep the system picker's header geometry with a plain album title.
        Stack({ alignContent: Alignment.Center }) {
          Text('我的相册').fontSize(20).fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary')).textAlign(TextAlign.Center)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(Math.max(40, Math.min(232, this.viewportWidth - 144))).height(40)
            .id('album-upload-picker-title')
          Row() {
            Blank().layoutWeight(1)
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.xmark')).fontSize(20).fontColor([$r('sys.color.icon_primary')])
            }.width(40).height(40).backgroundColor($r('app.color.album_picker_header'))
              .accessibilityText('关闭相册选择').id('album-upload-picker-close')
              .onClick(() => { this.generation++; this.visible = false })
          }.width('100%')
        }.width('100%').height(72).padding({ left: 16, right: 16 })
        if (this.loading || this.error) {
          Text(this.loading ? '正在读取所选相册的本地数量…' : this.error)
            .fontSize(13).fontColor(this.error ? $r('app.color.album_upload_error') : $r('sys.color.font_secondary'))
            .width('100%').padding({ left: 20, right: 20, top: 8, bottom: 12 })
        }
        Row() {
          Stack({ alignContent: Alignment.Bottom }) {
            AlbumPickerComponent({ albumPickerOptions: this.options,
              onAlbumClick: (info: AlbumInfo): boolean => { this.select(info); return true }
            }).width('100%').height('100%').id('album-upload-system-picker')
            // Only paint the edge: this layer must never receive native picker gestures.
            Column() {}.width('100%').height(Math.min(20, this.safeBottom))
              .linearGradient({ direction: GradientDirection.Bottom,
                colors: [[$r('app.color.album_picker_fade_start'), 0],
                  [$r('app.color.album_picker_background'), 1]] })
              .hitTestBehavior(HitTestMode.None)
          }.width('100%').height('100%')
            .borderRadius({ topLeft: 20, topRight: 20 }).clip(true)
        }.width('100%').layoutWeight(1).padding({ left: 16, right: 16 })
      }.width('100%').layoutWeight(1)
        .backgroundColor($r('app.color.album_picker_panel'))
        .borderRadius({ topLeft: 32, topRight: 32 }).clip(true)
    }.width('100%').height('100%')
      .padding({ top: this.safeTop + 8 })
      .backgroundColor(Color.Transparent)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

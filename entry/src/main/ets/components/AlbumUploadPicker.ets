import { common } from '@kit.AbilityKit'
import { AlbumPickerComponent, AlbumPickerOptions, AlbumInfo, PickerColorMode, photoAccessHelper } from '@kit.MediaLibraryKit'
import { LocalAlbumSource } from '../upload/LocalAlbumSource'
import { LocalImageAlbum } from '../upload/AlbumUploadModel'
import { FileRowStyle } from '../ui/FileRowStyle'
import { TaskPanel, TaskPanelSection } from './TaskPanel'

/** Only the system album list is shown here; upload options belong to the next page. */
@Component
export struct AlbumUploadPicker {
  @Link visible: boolean
  @Prop viewportWidth: number = 360
  @Prop viewportHeight: number = 800
  @Prop safeTop: number = 0
  @Prop safeBottom: number = 0
  onSelected: (album: LocalImageAlbum) => void = () => {}
  onNotice: (message: string) => void = () => {}
  @State loading: boolean = false
  private generation: number = 0
  private options: AlbumPickerOptions = { filterType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
    fontSize: FileRowStyle.titleSize, themeColorMode: PickerColorMode.AUTO }

  aboutToDisappear(): void { this.generation++ }

  private async select(info: AlbumInfo): Promise<void> {
    if (this.loading || !this.visible) { return }
    if (!info.uri) { this.onNotice('此相册暂不可读取，请选择具体相册'); return }
    const generation = ++this.generation
    this.loading = true
    try {
      const source = new LocalAlbumSource(getContext(this) as common.UIAbilityContext)
      await source.requestPermission(true)
      if (generation !== this.generation || !this.visible) { return }
      const album = await source.selectedAlbum(info.uri, info.albumName || '')
      if (generation === this.generation && this.visible) { this.onSelected(album) }
    } catch (error) {
      if (generation === this.generation && this.visible) {
        this.onNotice((error as Error).message || '相册读取失败，请重新选择')
      }
    } finally {
      if (generation === this.generation) { this.loading = false }
    }
  }

  @Builder
  PickerContent(): void {
    Stack() {
      TaskPanelSection({ fillHeight: true, paddingSize: 0 }) {
        AlbumPickerComponent({ albumPickerOptions: this.options,
          onAlbumClick: (info: AlbumInfo): boolean => { this.select(info); return true }
        }).width('100%').height('100%').id('album-upload-system-picker')
      }
      if (this.loading) {
        LoadingProgress().width(24).height(24).color($r('sys.color.comp_background_emphasize'))
          .accessibilityText('正在读取相册').hitTestBehavior(HitTestMode.None)
          .id('album-upload-picker-loading')
      }
    }.width('100%').height('100%')
  }

  build() {
    TaskPanel({ title: '我的相册', idPrefix: 'album-upload-picker', floating: true,
      viewportWidth: this.viewportWidth, viewportHeight: this.viewportHeight,
      safeTop: this.safeTop, safeBottom: this.safeBottom,
      onClose: (): void => { this.generation++; this.visible = false },
      content: (): void => { this.PickerContent() } })
  }
}

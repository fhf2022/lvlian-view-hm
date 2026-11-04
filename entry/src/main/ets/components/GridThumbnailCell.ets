import { image } from '@kit.ImageKit'
import { FileEntry } from '../model/FileEntry'
import { ImageLoadCompleteEvent } from '../media/ImageLoadEvent'

// One reusable state per cell; resolution must not read root @State.
export class GridImageState {
  available: boolean = false
  hidden: boolean = false
  source: image.PixelMap | string = ''
  orientation: ImageRotateOrientation = ImageRotateOrientation.UP
  transitionId: string = ''
  syncLoad: boolean = false
}

// Read local stores and entry fields only: keep dependencies inside the cell.
export class GridThumbnailBridge {
  resolveInto: (entry: FileEntry, state: GridImageState) => GridImageState =
    (entry: FileEntry, state: GridImageState): GridImageState => state
  icon: (entry: FileEntry) => Resource =
    (entry: FileEntry): Resource => $r('app.media.startIcon')
  onComplete: (entry: FileEntry, index: number, event?: ImageLoadCompleteEvent) => void =
    (entry: FileEntry, index: number, event?: ImageLoadCompleteEvent): void => {}
  onError: (entry: FileEntry) => void = (entry: FileEntry): void => {}
  // 🔬 OpenAnimProbe：cell 内 Image 节点出现（Q3 清理时删除）
  probeAppear: (entry: FileEntry, index: number) => void =
    (entry: FileEntry, index: number): void => {}
}

// Keep Image inline: an extra Builder or wrapper changes shared-element binding.
@Component
export struct GridThumbnailCell {
  @ObjectLink entry: FileEntry
  bridge: GridThumbnailBridge = new GridThumbnailBridge()
  index: number = 0
  private state: GridImageState = new GridImageState()

  private thumbState(): GridImageState {
    return this.bridge.resolveInto(this.entry, this.state)
  }

  build() {
    if (this.thumbState().available) {
      // Automatic decode sizing; keep the native Image inline for transitions.
      Image(this.thumbState().source)
        .width('100%')
        .height('100%')
        .orientation(this.state.orientation)
        .objectFit(ImageFit.Cover)
        .geometryTransition(this.state.transitionId)
        .syncLoad(this.state.syncLoad)
        .visibility(this.state.hidden ? Visibility.Hidden : Visibility.Visible)
        .onAppear((): void => {
          this.bridge.probeAppear(this.entry, this.index)
        })
        .onComplete((event?: ImageLoadCompleteEvent): void => {
          this.bridge.onComplete(this.entry, this.index, event)
        })
        .onError((): void => {
          this.bridge.onError(this.entry)
        })
    } else {
      Image(this.bridge.icon(this.entry))
        .width(48)
        .height(48)
        .objectFit(ImageFit.Contain)
    }
  }
}

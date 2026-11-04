import { image } from '@kit.ImageKit'
import { FileEntry } from '../model/FileEntry'
import { ImageLoadCompleteEvent } from '../media/ImageLoadEvent'

export class WaterfallImageState {
  available: boolean = false
  aspectReady: boolean = false
  failed: boolean = false
  source: image.PixelMap | string = ''
  orientation: ImageRotateOrientation = ImageRotateOrientation.UP
  transitionId: string = ''
  syncLoad: boolean = false
}

// Match the grid bridge contract: no root @State reads during cell build.
export class WaterfallThumbnailBridge {
  resolveInto: (entry: FileEntry, state: WaterfallImageState) => WaterfallImageState =
    (entry: FileEntry, state: WaterfallImageState): WaterfallImageState => state
  onComplete: (entry: FileEntry, index: number, event?: ImageLoadCompleteEvent) => void =
    (entry: FileEntry, index: number, event?: ImageLoadCompleteEvent): void => {}
  onError: (entry: FileEntry) => void = (entry: FileEntry): void => {}
}

// Preserve the native Stack/Image tree, aspect gating and loading placeholder.
@Component
export struct WaterfallThumbnailCell {
  @ObjectLink entry: FileEntry
  bridge: WaterfallThumbnailBridge = new WaterfallThumbnailBridge()
  index: number = 0
  private state: WaterfallImageState = new WaterfallImageState()

  private st(): WaterfallImageState {
    return this.bridge.resolveInto(this.entry, this.state)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.st().available) {
        if (this.st().aspectReady) {
          Image(this.st().source)
            .width('100%')
            .height('100%')
            .orientation(this.st().orientation)
            .objectFit(ImageFit.Contain)
            .geometryTransition(this.st().transitionId)
            .syncLoad(this.st().syncLoad)
            .opacity(1)
            .onComplete((event?: ImageLoadCompleteEvent): void => {
              this.bridge.onComplete(this.entry, this.index, event)
            })
            .onError((): void => {
              this.bridge.onError(this.entry)
            })
        } else {
          // 不传临时的 1:1 sourceSize：WaterFlow 回收 item 时 ArkUI 可能复用已解码的
          // raster，首次解码必须等 Image Kit 的真实几何，否则会把临时方框的目标尺寸固化。
          Image(this.st().source)
            .width('100%')
            .height('100%')
            .orientation(this.st().orientation)
            .objectFit(ImageFit.Contain)
            .geometryTransition(this.st().transitionId)
            .syncLoad(this.st().syncLoad)
            .opacity(0)
            .onComplete((event?: ImageLoadCompleteEvent): void => {
              this.bridge.onComplete(this.entry, this.index, event)
            })
            .onError((): void => {
              this.bridge.onError(this.entry)
            })
        }
      }
      if (this.st().failed) {
        Text('!').fontSize(22).fontColor('#888888')
      } else if (!this.st().available || !this.st().aspectReady) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color('#2E6BFF')
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(10)
    .clip(true)
  }
}

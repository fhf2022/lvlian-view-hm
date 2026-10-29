import { FileEntry } from '../model/FileEntry'
import { FileGridLayout } from '../ui/FileGridLayout'

export class FileGridCellEvents {
  click: (entry: FileEntry) => void = (_entry: FileEntry): void => {}
  visible: (entry: FileEntry, ratio: number) => void = (_entry: FileEntry, _ratio: number): void => {}
  longPress: (entry: FileEntry, event: GestureEvent) => void =
    (_entry: FileEntry, _event: GestureEvent): void => {}
  drag: (event: GestureEvent) => void = (_event: GestureEvent): void => {}
  dragEnd: (event: GestureEvent) => void = (_event: GestureEvent): void => {}
  dragCancel: () => void = (): void => {}
  isVideo: (entry: FileEntry) => boolean = (_entry: FileEntry): boolean => false
}

@Builder
function EmptyGridCellSlot(): void { Column() {}.width(0).height(0) }

// Keep the frequent native wrapper nodes in a small state owner. Image
// construction and file operations remain with their existing owners.
@Component
export struct FileGridCell {
  @ObjectLink entry: FileEntry
  @Prop selectionMode: boolean = false
  @Prop showName: boolean = false
  @Prop tileWidth: number = 120
  @Prop topInset: number = 0
  @Prop thumbnailId: string = ''
  @Prop tileId: string = ''
  events: FileGridCellEvents = new FileGridCellEvents()
  @BuilderParam content: () => void = EmptyGridCellSlot
  @BuilderParam videoIndicator: () => void = EmptyGridCellSlot
  @BuilderParam selectionIndicator: () => void = EmptyGridCellSlot

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: 0 }) {
        Stack({ alignContent: Alignment.Center }) {
          if (this.showName) {
            Column({ space: Math.max(4, Math.min(10, this.tileWidth * 0.04)) }) {
              Stack({ alignContent: Alignment.Center }) {
                this.content()
              }
              .width(FileGridLayout.fileIconSize(this.tileWidth))
              .height(FileGridLayout.fileIconSize(this.tileWidth))
              // Shared-element media flights start at the artwork, not the
              // surrounding card or its filename.
              .id(this.thumbnailId)
              Text(this.entry.name)
                .fontSize(FileGridLayout.fileLabelFontSize(this.tileWidth))
                .lineHeight(FileGridLayout.fileLabelFontSize(this.tileWidth) * 1.35)
                .fontColor($r('app.color.text_primary'))
                .maxLines(2)
                .height(FileGridLayout.fileLabelFontSize(this.tileWidth) * 2.7)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding({ left: Math.max(6, Math.min(16, this.tileWidth * 0.06)),
              right: Math.max(6, Math.min(16, this.tileWidth * 0.06)) })
          } else {
            this.content()
          }
        }
        .width('100%')
        .aspectRatio(1)
        .borderRadius(0)
        .id(this.showName ? this.tileId : this.thumbnailId)
        .onVisibleAreaChange([0.0, 0.999], (_expanding: boolean, ratio: number): void => {
          this.events.visible(this.entry, ratio)
        })
      }
      .width('100%')
      .padding(FileGridLayout.cellPadding)
      if (this.events.isVideo(this.entry)) {
        Image($r('app.media.video_thumbnail_badge'))
          .width(Math.max(12, Math.min(22, this.tileWidth * 0.1)))
          .aspectRatio(1.5)
          .objectFit(ImageFit.Contain)
          .position({ left: Math.max(4, this.tileWidth * 0.03),
            bottom: Math.max(4, this.tileWidth * 0.03) })
          .draggable(false)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
          .id('file-grid-video-badge:' + this.entry.path)
        this.videoIndicator()
      }
      if (this.selectionMode) {
        Row() {
          this.selectionIndicator()
        }
        .margin({ bottom: 6, right: 6 })
      }
    }
    // The first-row inset is content margin, retaining the immersive
    // scrolling and the existing shared-element thumbnail rectangle.
    .margin({ top: this.topInset })
    .onClick((): void => this.events.click(this.entry))
    .priorityGesture(
      GestureGroup(GestureMode.Sequence,
        LongPressGesture({ repeat: false, duration: 380 })
          .onAction((event: GestureEvent): void => this.events.longPress(this.entry, event)),
        PanGesture({ direction: PanDirection.All, distance: 8 })
          .onActionStart((event: GestureEvent): void => this.events.drag(event))
          .onActionUpdate((event: GestureEvent): void => this.events.drag(event))
          .onActionEnd((event: GestureEvent): void => this.events.dragEnd(event))
          .onActionCancel((): void => this.events.dragCancel())
      ).onCancel((): void => this.events.dragCancel())
    )
  }
}

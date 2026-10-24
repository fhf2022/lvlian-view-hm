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
  @Prop topInset: number = 0
  @Prop thumbnailId: string = ''
  events: FileGridCellEvents = new FileGridCellEvents()
  @BuilderParam content: () => void = EmptyGridCellSlot
  @BuilderParam videoIndicator: () => void = EmptyGridCellSlot
  @BuilderParam selectionIndicator: () => void = EmptyGridCellSlot

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: 0 }) {
        Stack({ alignContent: Alignment.Center }) {
          this.content()
        }
        .width('100%')
        .aspectRatio(1)
        .borderRadius(0)
        .id(this.thumbnailId)
        .onVisibleAreaChange([0.0, 0.999], (_expanding: boolean, ratio: number): void => {
          this.events.visible(this.entry, ratio)
        })
        if (this.entry.isDirectory) {
          Text(this.entry.name)
            .fontSize(11)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 2 })
        }
      }
      .width('100%')
      .padding(FileGridLayout.cellPadding)
      if (this.events.isVideo(this.entry)) {
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

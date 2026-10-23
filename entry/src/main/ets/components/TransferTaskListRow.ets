import { DownloadTaskRecord } from '../model/FileEntry'

// ForEach keeps each row by task ID. Subscribe to the task itself here rather
// than freezing primitive values in a by-value @Builder call in the parent.
@Component
export struct TransferQueueTaskRow {
  @ObjectLink task: DownloadTaskRecord
  infoForTask: (task: DownloadTaskRecord) => string = (): string => ''
  progressForTask: (task: DownloadTaskRecord) => number = (): number => 0
  @BuilderParam leading: () => void

  build() {
    TransferTaskListRow({ title: this.task.name, info: this.infoForTask(this.task),
      progress: this.progressForTask(this.task), loading: this.task.status === 'downloading' && this.task.size <= 0 }) {
      this.leading()
    }
  }
}

@Component
export struct TransferTaskListRow {
  @Prop title: string = ''
  @Prop info: string = ''
  @Prop progress: number = 0
  @Prop loading: boolean = false
  @Prop infoColor: ResourceColor = $r('app.color.text_muted')
  @BuilderParam leading: () => void = this.ImageIcon

  @Builder
  ImageIcon(): void {
    Image($r('sys.media.ohos_ic_normal_white_grid_image'))
      .width(32)
      .height(32)
      .objectFit(ImageFit.Contain)
  }

  build() {
    Row() {
      Stack() {
        this.leading()
      }
      .width(40)
      .height(34)
      .borderRadius(6)
      .clip(true)
      .margin({ right: 8 })
      Column() {
        Text(this.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.info)
          .fontSize(12)
          .fontColor(this.infoColor)
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Progress({ value: this.progress, total: 100, type: ProgressType.Ring })
        .width(30)
        .height(30)
        .backgroundColor('#AAB3C1')
        .color('#2E6BFF')
        .style({
          strokeWidth: 3,
          enableSmoothEffect: false,
          status: this.loading ? ProgressStatus.LOADING : ProgressStatus.PROGRESSING
        })
        .margin({ left: 10, right: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider'), style: BorderStyle.Solid })
  }
}

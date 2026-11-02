import { DownloadTaskRecord } from '../model/FileEntry'
import { FileListRow } from './FileListRow'
import { FileRowStyle } from '../ui/FileRowStyle'

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
  @Prop expandable: boolean = false
  @Prop expanded: boolean = false
  onExpand: () => void = () => {}
  @BuilderParam leading: () => void = this.ImageIcon

  @Builder
  ImageIcon(): void {
    Image($r('sys.media.ohos_ic_normal_white_grid_image'))
      .width(32)
      .height(32)
      .objectFit(ImageFit.Contain)
  }

  @Builder
  LeadingContent(): void {
    Stack() { this.leading() }
      .width(FileRowStyle.leadingWidth).height(FileRowStyle.leadingHeight).borderRadius(6).clip(true)
  }

  @Builder
  ProgressContent(): void {
    Row({ space: 0 }) {
      if (this.expandable) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14)
            .fontColor([$r('app.color.text_muted')])
            .rotate({ angle: this.expanded ? 90 : 0 })
        }.width(32).height(32).padding(0).backgroundColor(Color.Transparent).stateEffect(false)
          .accessibilityText(this.expanded ? '收起明细' : '展开明细').onClick((): void => this.onExpand())
      }
      Progress({ value: this.progress, total: 100, type: ProgressType.Ring })
        .width(30).height(30).backgroundColor('#AAB3C1').color('#2E6BFF')
        .style({ strokeWidth: 3, enableSmoothEffect: false,
          status: this.loading ? ProgressStatus.LOADING : ProgressStatus.PROGRESSING })
        .margin({ left: 10, right: 8 })
    }
  }

  build() {
    FileListRow({ title: this.title, info: this.info, infoColor: this.infoColor,
      startInset: 16, endInset: 12, showDivider: true,
      leading: (): void => { this.LeadingContent() },
      trailing: (): void => { this.ProgressContent() } })
  }
}

import { DownloadTaskRecord } from '../model/FileEntry'
import { TransferTaskGroup } from '../transfer/TransferTaskGroup'
import { TransferTaskListRow, TransferQueueTaskRow } from './TransferTaskListRow'

/** One shared row, plus an optional bounded, indented list of the original file rows. */
@Component
export struct TransferGroupTaskRow {
  @ObjectLink group: TransferTaskGroup
  infoForTask: (task: DownloadTaskRecord) => string = (): string => ''
  progressForTask: (task: DownloadTaskRecord) => number = (): number => 0
  onActivate: (task: DownloadTaskRecord) => void = (): void => {}
  onRemove: (task: DownloadTaskRecord) => void = (): void => {}
  @BuilderParam leading: (task: DownloadTaskRecord) => void = this.DefaultLeading
  @BuilderParam folderLeading: () => void = this.DefaultFolderLeading
  @State expanded: boolean = false
  @State page: number = 0

  private pageIndex(): number { return Math.min(this.page, Math.floor(Math.max(0, this.group.tasks.length - 1) / 100)) }
  private items(): DownloadTaskRecord[] {
    const start = this.pageIndex() * 100
    return this.group.tasks.slice(start, start + 100)
  }

  @Builder
  DefaultLeading(_task: DownloadTaskRecord): void {
    SymbolGlyph($r('sys.symbol.square_stack_3d_fill')).fontSize(30).fontColor(['#2E6BFF'])
  }

  @Builder
  DefaultFolderLeading(): void {
    SymbolGlyph($r('sys.symbol.folder_fill')).fontSize(30).fontColor(['#E5B451'])
  }

  @Builder
  BatchIcon(): void {
    if (this.group.batchKind === 'folder') { this.folderLeading() }
    else { this.DefaultLeading(this.group) }
  }

  @Builder
  FileRow(task: DownloadTaskRecord): void {
    Stack() {
      TransferQueueTaskRow({ task: task, infoForTask: this.infoForTask,
        progressForTask: this.progressForTask,
        leading: (): void => { this.leading(task) } })
    }.width('100%')
      .onClick((): void => this.onActivate(task))
      .priorityGesture(LongPressGesture({ repeat: false }).onAction((): void => this.onRemove(task)))
      .id('transfer-file:' + task.id)
  }

  build() {
    Column() {
      if (this.group.grouped) {
        TransferTaskListRow({ title: this.group.name, info: this.group.info,
          progress: this.group.percent, loading: this.group.loading,
          expandable: true, expanded: this.expanded,
          onExpand: (): void => { this.expanded = !this.expanded },
          leading: (): void => { this.BatchIcon() } })
          .id('transfer-batch:' + this.group.batchId)
        if (this.expanded) {
          Column() {
            ForEach(this.items(), (task: DownloadTaskRecord) => {
              this.FileRow(task)
            }, (task: DownloadTaskRecord): string => task.id)
            if (this.group.tasks.length > 100) {
              Row({ space: 16 }) {
                Button('上一页').fontSize(14).height(36).backgroundColor(Color.Transparent).fontColor('#2E6BFF')
                  .enabled(this.pageIndex() > 0).onClick((): void => { this.page = this.pageIndex() - 1 })
                Text((this.pageIndex() + 1).toString()).fontSize(14).fontColor($r('app.color.text_secondary'))
                Button('下一页').fontSize(14).height(36).backgroundColor(Color.Transparent).fontColor('#2E6BFF')
                  .enabled((this.pageIndex() + 1) * 100 < this.group.tasks.length)
                  .onClick((): void => { this.page = this.pageIndex() + 1 })
              }.width('100%').justifyContent(FlexAlign.Center).padding(12)
            }
          }.width('100%').padding({ left: 24 })
            .id('transfer-batch-children:' + this.group.batchId)
        }
      } else { this.FileRow(this.group.tasks[0]) }
    }.width('100%')
  }
}

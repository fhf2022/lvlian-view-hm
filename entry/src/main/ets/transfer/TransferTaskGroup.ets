import { util } from '@kit.ArkTS'
import { DownloadTaskRecord, TransferBatchFields } from '../model/FileEntry'

/** One user operation. No scheduling or file IO belongs to this descriptor. */
export class TransferBatch implements TransferBatchFields {
  batchId: string = util.generateRandomUUID(false)
  batchName: string = ''
  batchKind: string = 'files'
  batchState: string = 'adding'
  ownerScope: string = ''

  constructor(folderName: string = '', ownerScope: string = '') {
    this.batchName = folderName
    this.batchKind = folderName.length > 0 ? 'folder' : 'files'
    this.ownerScope = ownerScope
  }
}

@Observed
export class TransferTaskGroup extends DownloadTaskRecord {
  grouped: boolean = false
  tasks: DownloadTaskRecord[] = []
  info: string = ''
  percent: number = 0
  loading: boolean = false
}

/** Stable row objects; one linear pass per queue publication, never per cell build. */
export class TransferTaskGroups {
  rows: TransferTaskGroup[] = []
  private retained: Map<string, TransferTaskGroup> = new Map<string, TransferTaskGroup>()

  update(tasks: DownloadTaskRecord[], uploading: boolean): void {
    const members = new Map<string, DownloadTaskRecord[]>()
    for (const task of tasks) {
      // Queue snapshots already filter accounts; include scope to isolate reused row state as well.
      const key = (task.sourceScope || task.destinationRoot) + ':' +
        (task.batchId ? 'batch:' + task.batchId : 'task:' + task.id)
      const values = members.get(key)
      if (values === undefined) { members.set(key, [task]) } else { values.push(task) }
    }
    const next = new Map<string, TransferTaskGroup>()
    const rows: TransferTaskGroup[] = []
    members.forEach((values: DownloadTaskRecord[], key: string): void => {
      const row = this.retained.get(key) ?? new TransferTaskGroup()
      row.id = key
      if (row.tasks.length !== values.length || values.some(
        (task: DownloadTaskRecord, index: number): boolean => row.tasks[index] !== task)) { row.tasks = values }
      row.grouped = values[0].batchId.length > 0
      if (!row.grouped) {
        const id = row.id
        DownloadTaskRecord.copyInto(values[0], row)
        row.id = id
      } else { this.summarize(row, values, uploading) }
      next.set(key, row); rows.push(row)
    })
    this.retained = next; this.rows = rows
  }

  private summarize(row: TransferTaskGroup, tasks: DownloadTaskRecord[], uploading: boolean): void {
    let bytes = 0, received = 0, done = 0, failed = 0, active = 0, queued = 0
    let wifi = 0, server = 0, adding = false, incomplete = false, unknown = false
    for (const task of tasks) {
      const size = Number.isFinite(task.size) ? Math.max(0, task.size) : 0
      bytes += size
      received += task.status === 'completed' ? size : Math.min(size,
        Number.isFinite(task.receivedBytes) ? Math.max(0, task.receivedBytes) : 0)
      if (task.status === 'completed') { done++ }
      else if (task.status === 'failed') { failed++ }
      else if (task.status === 'downloading') { active++ }
      else if (task.status === 'queued') { queued++ }
      else if (task.status === 'waiting_wifi') { wifi++ }
      else if (task.status === 'waiting_server') { server++ }
      if (size <= 0 && task.status !== 'completed') { unknown = true }
      adding = adding || task.batchState === 'adding'
      incomplete = incomplete || task.batchState === 'incomplete'
    }
    const complete = !adding && !incomplete && done === tasks.length
    DownloadTaskRecord.copyBatchInto(tasks[0], row)
    row.name = row.batchKind === 'folder' ? row.batchName : tasks.length.toString() + ' 个文件'
    row.size = bytes; row.receivedBytes = received
    row.percent = complete ? 100 : (bytes > 0 ? Math.min(99, received / bytes * 100) : 0)
    row.loading = adding || (active > 0 && unknown)
    const state = adding ? '正在加入' : (incomplete ? '部分文件未加入' :
      (active > 0 ? (uploading ? '上传中' : '下载中') : (queued > 0 ? '排队中' :
      (failed > 0 ? '有失败项' : (server > 0 ? '等待 NAS 连接' :
      (wifi > 0 ? '等待 WiFi' : (complete ? '已完成' : '已暂停')))))))
    row.info = done.toString() + '/' + tasks.length.toString() + ' 个文件 · ' + state +
      (failed > 0 && state !== '有失败项' ? ' · 失败 ' + failed.toString() : '')
    row.status = complete ? 'completed' : (active > 0 ? 'downloading' : 'paused')
  }
}

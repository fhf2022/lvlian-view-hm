export class TransferProgress {
  id: string = ''
  direction: string = 'upload'
  active: boolean = false
  pending: boolean = false
  bytes: number = 0
  doneBytes: number = 0
  count: number = 1
  done: number = 0
  skipped: number = 0
  failed: number = 0
  state: string = ''
}

export class TransferSummary {
  bytes: number = 0
  doneBytes: number = 0
  count: number = 0
  done: number = 0
  skipped: number = 0
  failed: number = 0
  uploads: number = 0
  downloads: number = 0
  percent: number = 0
  knownSize: boolean = true
  text: string = ''
}

/** Only the coordinator's current session is aggregated, never completed history. */
export function summarizeTransfers(tasks: TransferProgress[]): TransferSummary {
  const result = new TransferSummary()
  for (const task of tasks) {
    const size = Number.isFinite(task.bytes) ? Math.max(0, task.bytes) : 0
    result.bytes += size
    result.doneBytes += Math.min(size, Math.max(0, Number.isFinite(task.doneBytes) ? task.doneBytes : 0))
    result.count += task.count
    result.done += task.done
    result.skipped += task.skipped
    result.failed += task.failed
    if (task.direction === 'upload') { result.uploads += task.count } else { result.downloads += task.count }
    if (size <= 0) { result.knownSize = false }
  }
  const success = result.count > 0 && result.done >= result.count && result.failed === 0
  result.percent = result.bytes > 0 ? Math.min(success ? 100 : 99,
    Math.floor(result.doneBytes * 100 / result.bytes)) : 0
  const title = result.uploads > 0 && result.downloads > 0 ? '上传与下载' :
    (result.uploads > 0 ? '上传' : '下载')
  result.text = title + (result.knownSize ? ' ' + result.percent.toString() + '%' : '进行中') +
    ' · 已完成 ' + result.done.toString() + '/' + result.count.toString()
  if (result.skipped > 0) { result.text += ' · 跳过 ' + result.skipped.toString() }
  if (result.failed > 0) { result.text += ' · 失败 ' + result.failed.toString() }
  return result
}

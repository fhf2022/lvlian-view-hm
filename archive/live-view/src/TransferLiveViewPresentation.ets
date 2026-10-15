import { TransferSummary, TransferProgress } from './TransferProgress'

// These colours and proportions match the ring in ImageViewerBarContent.
export const TRANSFER_RING_BLUE: number = 0xFF2E6BFF
export const TRANSFER_RING_TRACK: number = 0xFFAAB3C1

export class TransferLiveViewPresentation {
  phase: string = 'active'
  direction: string = 'upload'
  percent: number = 0
  knownSize: boolean = true
  title: string = ''
  detail: string = ''
  keepTime: number = 0
  dark: boolean = false
  key: string = ''
}

export function transferEndPhase(tasks: TransferProgress[], summary: TransferSummary): string {
  if (summary.count === 0 || tasks.some((task: TransferProgress): boolean => task.state === 'cancelled')) {
    return 'cancelled'
  }
  if (summary.done >= summary.count && summary.failed === 0) { return 'completed' }
  if (summary.done + summary.failed >= summary.count && summary.failed > 0) { return 'failed' }
  return 'paused'
}

export function presentTransfer(summary: TransferSummary, phase: string, dark: boolean,
  tasks: TransferProgress[] = []): TransferLiveViewPresentation {
  const value = new TransferLiveViewPresentation()
  value.phase = phase; value.dark = dark
  value.direction = summary.uploads > 0 && summary.downloads > 0 ? 'both' :
    (summary.uploads > 0 ? 'upload' : 'download')
  value.knownSize = summary.knownSize
  value.percent = phase === 'completed' ? 100 : Math.max(0, Math.min(99, summary.percent))
  const action = value.direction === 'both' ? '传输' : (value.direction === 'upload' ? '上传' : '下载')
  value.title = action + '中'
  value.detail = (value.knownSize ? value.percent.toString() + '% · ' : '') +
    '已处理 ' + summary.done.toString() + '/' + summary.count.toString()
  if (phase === 'completed') {
    value.title = action + '完成'; value.detail = '已处理 ' + summary.done.toString() + '/' + summary.count.toString()
    value.keepTime = 30
  } else if (phase === 'failed') {
    value.title = (summary.done > 0 ? '部分' : '') + action + '失败'
    value.detail = '失败 ' + summary.failed.toString() + ' 项 · 点击查看'
    value.keepTime = 30
  } else if (phase === 'paused') {
    value.title = action + '已暂停'; value.detail = '点击查看传输任务'; value.keepTime = 15
    if (tasks.some((task: TransferProgress): boolean => task.state === 'waiting_server')) {
      value.detail = 'NAS 离线 · 点击查看'
    } else if (tasks.some((task: TransferProgress): boolean => task.state === 'waiting_wifi')) {
      value.detail = '等待网络 · 点击查看'
    }
  } else if (phase === 'cancelled') {
    value.title = action + '已结束'; value.detail = '传输已结束'
  }
  value.key = phase + ':' + value.direction + ':' + value.percent.toString() + ':' + value.knownSize.toString() +
    ':' + value.title + ':' + value.detail + ':' + dark.toString()
  return value
}

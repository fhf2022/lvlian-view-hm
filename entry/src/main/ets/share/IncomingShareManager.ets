import { Want } from '@kit.AbilityKit'
import { systemShare } from '@kit.ShareKit'

export class IncomingShare {
  id: number = 0
  uris: string[] = []
  error: string = ''
}

// Keep only URI grants in memory until the user chooses a destination. The
// upload queue owns durable, bounded staging; an unconfirmed share is never saved.
export class IncomingShareManager {
  private static instance: IncomingShareManager = new IncomingShareManager()
  private pending: IncomingShare[] = []
  private sequence: number = 0
  private generation: number = 0
  private parsing: Promise<void> = Promise.resolve()

  static shared(): IncomingShareManager { return IncomingShareManager.instance }

  receive(want: Want): void {
    if (want.action !== 'ohos.want.action.sendData') { return }
    const generation = this.generation
    // Reserve the place before asynchronous parsing so consecutive shares keep
    // arrival order and cannot grow an unbounded parsing backlog.
    if (this.pending.length >= 4) {
      if (this.pending.length === 4) {
        const overflow = new IncomingShare()
        overflow.id = ++this.sequence
        overflow.error = '待处理的分享较多，请先处理当前文件，再重新分享其余文件'
        this.pending.push(overflow)
        this.publish()
      }
      return
    }
    const request = new IncomingShare()
    request.id = ++this.sequence
    this.pending.push(request)
    this.parsing = this.parsing.then(async (): Promise<void> => {
      if (generation !== this.generation) { return }
      try {
        const data = await systemShare.getSharedData(want)
        if (generation !== this.generation) { return }
        const records = data.getRecords()
        if (records.length > 500) { throw new Error('一次最多接收 500 个文件') }
        const seen = new Set<string>()
        for (const record of records) {
          const uri = record.uri ?? ''
          if (uri.startsWith('file://') && !seen.has(uri)) {
            seen.add(uri)
            request.uris.push(uri)
          }
        }
        if (request.uris.length === 0) {
          request.error = '没有可读取的文件，请从来源应用分享文件后重试'
        }
      } catch (_) {
        request.error = '无法读取分享内容，请从来源应用重新分享文件'
      }
      if (generation === this.generation) { this.publish() }
    })
  }

  peek(): IncomingShare | undefined {
    const request = this.pending[0]
    return request !== undefined && (request.uris.length > 0 || request.error !== '') ? request : undefined
  }

  dismiss(id: number): void {
    if (this.pending[0]?.id !== id) { return }
    this.pending.shift()
    this.publish()
  }

  destroy(): void {
    this.generation++
    this.pending = []
    this.parsing = Promise.resolve()
  }

  private publish(): void {
    AppStorage.setOrCreate('incomingShareRequest', (AppStorage.get<number>('incomingShareRequest') ?? 0) + 1)
  }
}

import { Context } from '@kit.AbilityKit'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { DownloadTaskRecord } from '../model/FileEntry'
import { StorageBudget } from '../download/StorageBudget'
import { UgreenRemoteRepository } from '../repository/UgreenRemoteRepository'
import { NetworkPolicy } from '../core/network/NetworkPolicy'
import { NasConnection, NasConnectionState } from '../core/network/NasConnection'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'
import { TransferBackgroundManager } from '../transfer/TransferBackgroundManager'
import { TransferProgress } from '../transfer/TransferProgress'

export class UploadTaskRecord extends DownloadTaskRecord {
  uuid: string = ''
  scope: string = ''
  prepared: boolean = false
  importing: boolean = false
  skipped: boolean = false
}

/** Original bytes only. One bounded chunk in flight; acknowledged offsets are durable. */
export class UploadQueueManager {
  private tasks: UploadTaskRecord[] = []
  private repository: UgreenRemoteRepository | null = null
  private network: NetworkPolicy | null = null
  private prefs: preferences.Preferences | null = null
  private root: string = ''
  private ready: boolean = false
  private running: Promise<void> | null = null
  private listener: (tasks: UploadTaskRecord[]) => void = () => {}
  private saving: Promise<void> = Promise.resolve()
  private readonly chunkSize: number = 512 * 1024

  async initialize(context: Context, repository: UgreenRemoteRepository,
    network: NetworkPolicy, listener: (tasks: UploadTaskRecord[]) => void): Promise<void> {
    if (this.prefs !== null) { return }
    this.repository = repository
    this.network = network
    this.listener = listener
    this.root = context.filesDir + '/ugreen-upload-tasks'
    if (!fileIo.accessSync(this.root)) { fileIo.mkdirSync(this.root) }
    this.prefs = await preferences.getPreferences(context, 'ugreen-upload-tasks')
    this.tasks = JSON.parse(String(await this.prefs.get('tasks', '[]'))) as UploadTaskRecord[]
    this.tasks = this.tasks.filter((task: UploadTaskRecord): boolean =>
      task.id.startsWith('upload:') && /^[a-zA-Z0-9-]+$/.test(task.uuid) &&
      task.stagingPath === this.root + '/' + task.uuid + '.part')
    for (const task of this.tasks) {
      if (task.importing) {
        task.importing = false
        task.status = 'failed'
        task.errorMessage = '导入中断，请重新选择文件'
        StorageBudget.removeWhenUnused(task.stagingPath)
      } else if (task.status === 'downloading' || task.status === 'queued') { task.status = 'paused' }
      if (task.status === 'completed') { StorageBudget.removeWhenUnused(task.stagingPath) }
    }
    // Only files in our own staging root can be orphaned/removed.
    for (const name of fileIo.listFileSync(this.root)) {
      const path = this.root + '/' + name
      if (!this.tasks.some((task: UploadTaskRecord): boolean => task.stagingPath === path)) {
        StorageBudget.removeWhenUnused(path)
      }
    }
    StorageBudget.onEvicted((path: string): void => {
      const task = this.tasks.find((item: UploadTaskRecord): boolean => item.stagingPath === path)
      if (task !== undefined && task.status !== 'completed') {
        task.status = 'failed'
        task.errorMessage = '暂存已回收，请重新选择文件'
        this.publish()
        this.persist().catch(() => {})
      }
    })
    network.onChange(() => {
      for (const task of this.snapshot()) {
        if (task.status === 'waiting_wifi' && network.isUnmetered()) { task.status = 'queued' }
      }
      this.publish()
      this.pump()
    })
    NasConnection.shared().onChange((state: NasConnectionState): void => {
      for (const task of this.snapshot()) {
        if (state === 'online' && task.status === 'waiting_server') { task.status = 'queued' }
        else if ((state === 'unavailable' || state === 'connecting') &&
          (task.status === 'queued' || task.status === 'downloading')) { task.status = 'waiting_server' }
      }
      this.persist().catch(() => {})
      this.publish()
      this.pump()
    })
    await this.persist()
    TransferBackgroundManager.shared().onChange(() => { this.pump() })
    TransferBackgroundManager.shared().onCancel(() => {
      for (const task of this.snapshot()) {
        if (task.status === 'queued' || task.status === 'downloading') { task.status = 'paused' }
      }
      this.persist().catch(() => {}); this.publish()
    })
    this.publish()
  }

  snapshot(): UploadTaskRecord[] {
    const scope = this.repository === null ? '' : this.repository.cacheScopeHash()
    return this.tasks.filter((task: UploadTaskRecord): boolean => scope.length > 0 && task.scope === scope)
  }
  async setReady(value: boolean): Promise<void> {
    this.ready = value
    if (value && NasConnection.shared().canRequest()) {
      for (const task of this.snapshot()) {
        if (task.status === 'waiting_server') { task.status = 'queued' }
      }
    }
    if (!value) {
      for (const task of this.tasks) {
        if (task.status === 'downloading' || task.status === 'queued') { task.status = 'paused' }
      }
      if (this.running !== null) { await this.running }
      await this.persist()
    }
    this.publish()
    this.pump()
  }

  async enqueue(uri: string, dir: string, scope: string): Promise<void> {
    await TransferBackgroundManager.shared().requestResume()
    if (this.repository === null || !this.ready || scope !== this.repository.cacheScopeHash()) {
      throw new Error('登录状态已改变，请重新选择上传文件')
    }
    const task = new UploadTaskRecord()
    task.uuid = util.generateRandomUUID(false)
    task.id = 'upload:' + task.uuid
    task.scope = scope
    task.name = new fileUri.FileUri(uri).name
    if (!task.name || /[\r\n\/\\]/.test(task.name)) { throw new Error('文件名无效') }
    task.destinationRoot = dir
    task.remotePath = dir.replace(/\/$/, '') + '/' + task.name
    task.stagingPath = this.root + '/' + task.uuid + '.part'
    task.createdAt = Date.now()
    task.updatedAt = task.createdAt
    task.importing = true
    task.status = 'paused'
    const source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)
    let target: fileIo.File | null = null
    this.tasks.unshift(task)
    StorageBudget.pin(task.stagingPath)
    try {
      task.size = (await fileIo.stat(source.fd)).size
      await this.persist()
      this.publish()
      // Admission before creating a large staging copy; every actual write is also admitted.
      StorageBudget.admit(task.stagingPath, task.size)
      target = fileIo.openSync(task.stagingPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE)
      let copied = 0
      while (copied < task.size) {
        if (!this.ready || scope !== this.repository.cacheScopeHash()) { throw new Error('导入已中止') }
        const buffer = new ArrayBuffer(Math.min(this.chunkSize, task.size - copied))
        const read = await fileIo.read(source.fd, buffer, { offset: copied })
        if (read <= 0) { throw new Error('读取原文件失败') }
        StorageBudget.admit(task.stagingPath, copied + read)
        const written = fileIo.writeSync(target.fd, buffer, { offset: copied, length: read })
        StorageBudget.sync(task.stagingPath)
        if (written !== read) { throw new Error('暂存写入不完整') }
        copied += read
      }
      task.importing = false
      task.status = 'queued'
    } catch (error) {
      task.importing = false
      task.status = 'failed'
      task.errorMessage = String((error as Error).message || '文件导入失败')
      StorageBudget.removeWhenUnused(task.stagingPath)
    } finally {
      fileIo.closeSync(source)
      if (target !== null) { fileIo.closeSync(target) }
      StorageBudget.unpin(task.stagingPath)
      await this.persist()
      this.publish()
      this.pump()
    }
  }

  async toggle(id: string): Promise<void> {
    const task = this.snapshot().find((item: UploadTaskRecord): boolean => item.id === id)
    if (task === undefined || task.importing || task.status === 'completed') { return }
    if (task.status === 'waiting_server') {
      await NasConnection.shared().retryNow()
      this.pump()
      return
    }
    if (task.status === 'downloading' || task.status === 'queued') { task.status = 'paused' }
    else {
      if (!fileIo.accessSync(task.stagingPath)) { throw new Error('暂存不存在，请重新选择原文件') }
      await TransferBackgroundManager.shared().requestResume()
      if (!this.ready || this.repository === null || task.scope !== this.repository.cacheScopeHash()) {
        throw new Error('登录状态已改变，请重新选择上传文件')
      }
      // A deliberate tap can continue this task on a metered connection.
      task.manualMobileResume = true
      task.errorMessage = ''
      task.status = 'queued'
    }
    await this.persist()
    this.publish()
    this.pump()
  }

  async remove(id: string): Promise<void> {
    const task = this.snapshot().find((item: UploadTaskRecord): boolean => item.id === id)
    if (task === undefined || task.importing) { return }
    const complete = task.status === 'completed'
    if (!complete) { task.status = 'paused' }
    if (this.running !== null) { await this.running }
    // Keep the record and source if remote cleanup fails, so a retry remains possible.
    if (!complete && task.status !== 'completed' && task.prepared && this.repository !== null) {
      await this.repository.removeUploadTemporary(task.destinationRoot, task.uuid)
    }
    this.tasks = this.tasks.filter((item: UploadTaskRecord): boolean => item.id !== id)
    await this.persist()
    StorageBudget.removeWhenUnused(task.stagingPath)
    this.publish()
  }

  private pump(): void {
    if (!this.ready || this.running !== null || this.repository === null) { return }
    if (!TransferBackgroundManager.shared().canRun()) { this.publish(); return }
    const task = this.snapshot().find((item: UploadTaskRecord): boolean => item.status === 'queued')
    if (task === undefined) { return }
    if (!NasConnection.shared().canRequest()) {
      for (const queued of this.snapshot()) {
        if (queued.status === 'queued') { queued.status = 'waiting_server' }
      }
      this.persist().catch(() => {})
      this.publish()
      return
    }
    if (this.network !== null && (this.network.current() === 'offline' ||
      (!this.network.isUnmetered() && !task.manualMobileResume))) {
      task.status = 'waiting_wifi'
      this.publish()
      this.pump()
      return
    }
    this.running = this.run(task).catch(() => {}).finally(() => {
      this.running = null
      this.pump()
    })
  }

  private async run(task: UploadTaskRecord): Promise<void> {
    const repository = this.repository
    if (repository === null) { return }
    task.status = 'downloading'
    StorageBudget.pin(task.stagingPath)
    let source: fileIo.File | null = null
    try {
      source = await fileIo.open(task.stagingPath, fileIo.OpenMode.READ_ONLY)
      if ((await fileIo.stat(source.fd)).size !== task.size) { throw new Error('暂存不完整，请重新选择原文件') }
      // Persist the remote-cleanup obligation before issuing the request (including a lost reply).
      task.prepared = true
      await this.persist()
      task.skipped = await repository.prepareUpload(task.destinationRoot, task.name,
        task.uuid, task.size, task.createdAt)
      if (task.skipped) { task.status = 'completed' }
      else {
        let offset = await repository.uploadOffset(task.destinationRoot, task.uuid, task.size)
        task.receivedBytes = offset
        while (this.ready && task.status === 'downloading') {
          if (!TransferBackgroundManager.shared().canRun()) { task.status = 'queued'; break }
          if (!NasConnection.shared().canRequest()) { task.status = 'waiting_server'; break }
          if (this.network !== null && (this.network.current() === 'offline' ||
            (!this.network.isUnmetered() && !task.manualMobileResume))) {
            task.status = 'waiting_wifi'
            break
          }
          const bytes = new ArrayBuffer(Math.min(this.chunkSize, task.size - offset))
          if (bytes.byteLength > 0) {
            const count = await fileIo.read(source.fd, bytes, { offset: offset })
            if (count !== bytes.byteLength) { throw new Error('读取上传分块失败') }
          }
          await repository.uploadChunk(task.destinationRoot, task.name, task.uuid,
            task.size, task.createdAt, offset, bytes)
          offset += bytes.byteLength
          task.receivedBytes = offset
          if (offset >= task.size) { task.status = 'completed' }
          task.updatedAt = Date.now()
          await this.persist()
          this.publish()
          if (task.status === 'completed') { break }
        }
      }
      await this.persist()
      if (task.status === 'completed') { StorageBudget.removeWhenUnused(task.stagingPath) }
    } catch (error) {
      if (String(task.status) !== 'paused' && error instanceof UgreenError &&
        error.kind === UgreenErrorKind.NAS_UNAVAILABLE) {
        task.status = NasConnection.shared().canRequest() ? 'queued' : 'waiting_server'
        task.errorMessage = ''
      } else if (String(task.status) !== 'paused' && String(task.status) !== 'waiting_server') {
        task.status = 'failed'
        task.errorMessage = String((error as Error).message || '上传失败')
      }
      await this.persist()
    } finally {
      if (source !== null) { fileIo.closeSync(source) }
      StorageBudget.unpin(task.stagingPath)
      this.publish()
    }
  }

  private publish(): void {
    const tasks = this.snapshot()
    TransferBackgroundManager.shared().update('upload', tasks.map((task: UploadTaskRecord): TransferProgress => {
      const value = new TransferProgress()
      value.id = task.id; value.direction = 'upload'; value.bytes = task.size
      value.doneBytes = task.status === 'completed' ? task.size : task.receivedBytes
      value.done = task.status === 'completed' ? 1 : 0
      value.skipped = task.skipped && value.done > 0 ? 1 : 0
      value.state = this.ready ? task.status : 'cancelled'
      value.failed = task.status === 'failed' ? 1 : 0
      value.pending = !task.importing && (task.status === 'queued' || task.status === 'downloading')
      value.active = this.ready && value.pending && NasConnection.shared().canRequest() &&
        this.network !== null && this.network.current() !== 'offline' &&
        (this.network.isUnmetered() || task.manualMobileResume)
      return value
    }))
    this.listener(tasks.slice())
  }
  private persist(): Promise<void> {
    const prefs = this.prefs
    if (prefs === null) { return Promise.resolve() }
    // Completed metadata is bounded; active sources are never removed by history pruning.
    let completed = 0
    this.tasks = this.tasks.filter((task: UploadTaskRecord): boolean => {
      if (task.status !== 'completed') { return true }
      completed += 1
      return completed <= 200 && Date.now() - task.updatedAt < 30 * 86400000
    })
    const value = JSON.stringify(this.tasks)
    this.saving = this.saving.catch(() => {}).then(async (): Promise<void> => {
      await prefs.put('tasks', value)
      await prefs.flush()
    })
    return this.saving
  }
}

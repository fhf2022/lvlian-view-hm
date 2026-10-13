import { common } from '@kit.AbilityKit'
import { fileIo } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { AlbumUploadItem, AlbumUploadJob, AlbumUploadPolicy, AlbumUploadSource, LocalImageAlbum } from './AlbumUploadModel'
import { AlbumUploadStore } from './AlbumUploadStore'
import { LocalAlbumSource } from './LocalAlbumSource'
import { StorageBudget } from '../download/StorageBudget'
import { UgreenRemoteRepository } from '../repository/UgreenRemoteRepository'
import { NetworkPolicy } from '../core/network/NetworkPolicy'
import { NasConnection } from '../core/network/NasConnection'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'
import { TransferBackgroundManager } from '../transfer/TransferBackgroundManager'
import { TransferProgress } from '../transfer/TransferProgress'

/** One original and one 512 KiB request at a time. SQLite owns the complete manifest. */
export class AlbumUploadManager {
  private store: AlbumUploadStore = new AlbumUploadStore()
  private jobs: AlbumUploadJob[] = []
  private context: common.UIAbilityContext | null = null
  private repository: UgreenRemoteRepository | null = null
  private network: NetworkPolicy | null = null
  private source: AlbumUploadSource | null = null
  private listener: (jobs: AlbumUploadJob[]) => void = () => {}
  private changed: (destination: string) => void = () => {}
  private running: Promise<void> | null = null
  private ready: boolean = false
  private creating: boolean = false
  private root: string = ''
  private staged: string = ''
  private publishedAt: number = 0
  private readonly chunkSize: number = 512 * 1024

  async initialize(context: common.UIAbilityContext, repository: UgreenRemoteRepository, network: NetworkPolicy,
    listener: (jobs: AlbumUploadJob[]) => void, changed: (destination: string) => void,
    source: AlbumUploadSource = new LocalAlbumSource(context)): Promise<void> {
    if (this.context) { return }
    await this.store.initialize(context)
    await this.store.prune()
    this.jobs = await this.store.jobs()
    for (const job of this.jobs) { await this.store.recount(job) }
    for (const job of this.snapshotForLog()) { console.info('[AlbumUpload] restored ' + job) }
    this.root = context.filesDir + '/ugreen-album-uploads'
    if (!fileIo.accessSync(this.root)) { fileIo.mkdirSync(this.root) }
    // A interrupted local copy is never trusted; the immutable source version is checked again.
    for (const name of fileIo.listFileSync(this.root)) {
      if (/^[a-zA-Z0-9-]+\.part$/.test(name)) { StorageBudget.removeWhenUnused(this.root + '/' + name) }
    }
    this.context = context; this.repository = repository; this.network = network; this.source = source
    this.listener = listener; this.changed = changed
    network.onChange(() => { this.kick() })
    NasConnection.shared().onChange(() => { this.kick() })
    TransferBackgroundManager.shared().onChange(() => { this.kick() })
    TransferBackgroundManager.shared().onCancel(() => {
      for (const job of this.snapshot()) {
        if (AlbumUploadPolicy.canRun(job.state)) {
          job.state = 'paused'
          this.store.save(job).catch(() => {})
        }
      }
      this.publish()
    })
    this.publish()
  }
  snapshot(): AlbumUploadJob[] {
    const scope = this.repository ? this.repository.cacheScopeHash() : ''
    return this.jobs.filter((job: AlbumUploadJob): boolean => scope.length > 0 && job.scope === scope)
  }
  protectedPaths(): string[] { return this.staged ? [this.staged] : [] }
  setForeground(value: boolean): void {
    // Execution eligibility belongs to the UIAbility's transfer coordinator.
    this.kick()
  }
  async setReady(value: boolean): Promise<void> {
    this.ready = value
    if (!value) {
      if (this.running) { await this.running }
      for (const job of this.snapshot()) {
        if (AlbumUploadPolicy.canRun(job.state)) { job.state = 'paused'; await this.store.save(job) }
      }
    }
    this.publish(); this.kick()
  }
  private checkScope(job: AlbumUploadJob): void {
    if (!this.ready || !this.repository || job.scope !== this.repository.cacheScopeHash()) {
      throw new Error('登录状态已改变，上传已暂停')
    }
  }
  async create(album: LocalImageAlbum, destination: string, rootType: number,
    scope: string, keepOn: boolean): Promise<void> {
    if (!this.source || !this.context) { throw new Error('上传任务尚未就绪') }
    if (this.creating) { throw new Error('正在整理另一个图片文件夹') }
    if (this.snapshot().filter((job: AlbumUploadJob): boolean => job.state !== 'completed').length >= 5) {
      throw new Error('请先完成或移除已有任务，再添加新的图片文件夹')
    }
    if (!destination || !album.uri) { throw new Error('请选择本地图片文件夹和 NAS 目标文件夹') }
    const job = new AlbumUploadJob()
    job.id = util.generateRandomUUID(false); job.scope = scope; job.albumUri = album.uri; job.albumName = album.name
    job.destination = destination; job.rootType = rootType; job.keepScreenOn = false; job.createdAt = Date.now()
    this.checkScope(job)
    this.creating = true; this.jobs.unshift(job)
    try {
      await TransferBackgroundManager.shared().requestResume()
      this.checkScope(job)
      await this.store.save(job); this.publish()
      job.total = await this.source.snapshot(album, async (items: AlbumUploadItem[]): Promise<void> => {
        this.checkScope(job)
        for (const item of items) { job.bytes += item.size }
        await this.store.append(job.id, items)
      }, (): void => { this.checkScope(job) })
      this.checkScope(job)
      job.state = 'queued'; await this.store.save(job)
    } catch (error) {
      await this.store.remove(job.id)
      this.jobs = this.jobs.filter((entry: AlbumUploadJob): boolean => entry.id !== job.id)
      throw error as Error
    } finally { this.creating = false; this.publish(); this.kick() }
  }
  async toggle(id: string): Promise<void> {
    const job = this.snapshot().find((entry: AlbumUploadJob): boolean => entry.id === id)
    if (!job || job.state === 'building' || job.state === 'completed') { return }
    if (job.total === 0) { throw new Error('整理中断，请移除任务后重新选择图片文件夹') }
    if (job.state === 'running' || job.state === 'checking' || job.state === 'queued') { job.state = 'paused' }
    else {
      await TransferBackgroundManager.shared().requestResume()
      this.checkScope(job)
      if (job.state === 'failed') { await this.store.retry(job.id); await this.store.recount(job) }
      job.state = 'queued'; job.error = ''
    }
    await this.store.save(job); this.publish(); this.kick()
    if (!NasConnection.shared().canRequest()) { await NasConnection.shared().retryNow() }
  }
  async details(id: string, offset: number, failures: boolean): Promise<AlbumUploadItem[]> {
    if (!this.snapshot().some((job: AlbumUploadJob): boolean => job.id === id)) { return [] }
    return await this.store.items(id, offset, failures)
  }
  async remove(id: string): Promise<void> {
    const job = this.snapshot().find((entry: AlbumUploadJob): boolean => entry.id === id)
    if (!job || job.state === 'building') { return }
    job.state = 'paused'; await this.store.save(job); this.publish()
    if (this.running) { await this.running }
    this.checkScope(job)
    for (let offset = 0; ; offset += 100) {
      const items = await this.store.items(job.id, offset)
      for (const item of items) {
        if (item.prepared && item.state !== 'uploaded' && item.state !== 'skipped') {
          await this.repository!.removeUploadTemporary(job.destination, item.id)
        }
      }
      if (items.length < 100) { break }
    }
    await this.store.remove(job.id)
    this.jobs = this.jobs.filter((entry: AlbumUploadJob): boolean => entry.id !== id)
    this.publish()
  }
  private kick(): void {
    if (this.running || !this.ready || !this.context) { return }
    const job = this.snapshot().find((entry: AlbumUploadJob): boolean => AlbumUploadPolicy.canRun(entry.state))
    if (!job) { return }
    this.running = this.run(job).catch(async (error: Error): Promise<void> => {
      job.state = 'failed'; job.error = error.message || '上传任务存储失败'
      await this.store.save(job).catch(() => {})
    }).finally(() => {
      this.running = null; this.publish()
      console.info('[AlbumUpload] state=' + job.state + ' total=' + job.total.toString() +
        ' uploaded=' + job.uploaded.toString() + ' skipped=' + job.skipped.toString() + ' failed=' + job.failed.toString())
      // Waiting states resume from network/foreground events, without a polling loop.
      if (job.state === 'completed' || job.state === 'failed' || job.state === 'paused' ||
        (job.state === 'waiting_foreground' && TransferBackgroundManager.shared().canRun()) ||
        (job.state === 'waiting_wifi' && this.network !== null && this.network.isUnmetered()) ||
        (job.state === 'waiting_server' && NasConnection.shared().current() === 'online')) { this.kick() }
    })
  }
  private runnable(job: AlbumUploadJob): boolean {
    if (!this.ready || !this.repository || job.scope !== this.repository.cacheScopeHash()) { job.state = 'paused'; return false }
    if (job.state === 'paused') { return false }
    if (!TransferBackgroundManager.shared().canRun()) { job.state = 'waiting_foreground'; return false }
    if (!this.network || !this.network.isUnmetered()) { job.state = 'waiting_wifi'; return false }
    if (!NasConnection.shared().canRequest()) { job.state = 'waiting_server'; return false }
    return true
  }
  private async indexRemote(job: AlbumUploadJob): Promise<boolean> {
    await this.store.clearRemote(job.id)
    for (let pageIndex = 1; ; pageIndex++) {
      if (!this.runnable(job)) { return false }
      const page = await this.repository!.listUploadDestinationPage(job.destination, job.rootType, pageIndex)
      this.checkScope(job)
      await this.store.remotePage(job.id, page.entries.map((entry): string => entry.name),
        page.entries.map((entry): number => entry.size), page.entries.map((entry): boolean => entry.isDirectory))
      if (!page.hasMore) { return true }
      if (pageIndex >= 1000 || page.entries.length === 0) { throw new Error('NAS 目录分页异常，请稍后重试') }
    }
  }
  private async target(job: AlbumUploadJob, item: AlbumUploadItem): Promise<boolean> {
    if (!AlbumUploadPolicy.validName(item.name) || !Number.isFinite(item.size) || item.size <= 0) {
      throw new Error('图片文件名或大小无效')
    }
    let name = item.targetName || await this.store.priorName(job, item) || item.name
    for (let attempt = 0; attempt < 100; attempt++) {
      const size = await this.store.remote(job.id, name)
      if (size === null || size === item.size) {
        item.targetName = name
        await this.store.update(item)
        return size === item.size
      }
      name = AlbumUploadPolicy.alternateName(item, attempt)
    }
    throw new Error('同名图片过多，请整理 NAS 文件夹后重试')
  }
  private async verifyRemote(job: AlbumUploadJob, item: AlbumUploadItem): Promise<boolean> {
    for (let pageIndex = 1; ; pageIndex++) {
      if (!this.runnable(job)) { return false }
      const page = await this.repository!.listUploadDestinationPage(job.destination, job.rootType, pageIndex)
      this.checkScope(job)
      const found = page.entries.find((entry): boolean => entry.name === item.targetName)
      if (found) { return !found.isDirectory && found.size === item.size }
      if (!page.hasMore) { return false }
    }
  }
  private async stage(job: AlbumUploadJob, item: AlbumUploadItem, path: string): Promise<boolean> {
    await this.source!.validate(item)
    const original = await fileIo.open(item.uri, fileIo.OpenMode.READ_ONLY)
    let target: fileIo.File | null = null
    try {
      const before = await fileIo.stat(original.fd)
      if (before.size !== item.size) { throw new Error('原图大小发生变化，请重新创建任务') }
      StorageBudget.admit(path, item.size)
      target = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC)
      let offset = 0
      while (offset < item.size) {
        if (!this.runnable(job)) { return false }
        const bytes = new ArrayBuffer(Math.min(this.chunkSize, item.size - offset))
        const count = await fileIo.read(original.fd, bytes, { offset: offset })
        if (count !== bytes.byteLength) { throw new Error('原图读取不完整') }
        StorageBudget.admit(path, offset + count)
        if (fileIo.writeSync(target.fd, bytes, { offset: offset, length: count }) !== count) { throw new Error('原图暂存不完整') }
        offset += count; StorageBudget.sync(path)
      }
      const after = await fileIo.stat(original.fd)
      if (after.size !== before.size || after.mtime !== before.mtime) { throw new Error('读取期间图片发生变化，请重新创建任务') }
      await this.source!.validate(item)
      return true
    } finally { fileIo.closeSync(original); if (target) { fileIo.closeSync(target) } }
  }
  private async upload(job: AlbumUploadJob, item: AlbumUploadItem): Promise<void> {
    const path = this.root + '/' + item.id + '.part'
    this.staged = path; StorageBudget.pin(path)
    let source: fileIo.File | null = null
    try {
      if (!await this.stage(job, item, path) || !this.runnable(job)) { return }
      item.prepared = true; await this.store.update(item)
      const skip = await this.repository!.prepareUpload(job.destination, item.targetName, item.id, item.size, item.modified)
      this.checkScope(job)
      if (skip) {
        if (!await this.verifyRemote(job, item)) {
          if (!this.runnable(job)) { return }
          throw new Error('NAS 同名文件信息发生变化，请重试以重新检查')
        }
        item.state = 'skipped'; return
      }
      if (!this.runnable(job)) { return }
      source = await fileIo.open(path, fileIo.OpenMode.READ_ONLY)
      let offset = await this.repository!.uploadOffset(job.destination, item.id, item.size)
      while (this.runnable(job)) {
        const bytes = new ArrayBuffer(Math.min(this.chunkSize, item.size - offset))
        if (bytes.byteLength > 0 && await fileIo.read(source.fd, bytes, { offset: offset }) !== bytes.byteLength) {
          throw new Error('暂存读取不完整')
        }
        await this.repository!.uploadChunk(job.destination, item.targetName, item.id, item.size, item.modified, offset, bytes)
        this.checkScope(job)
        offset += bytes.byteLength; job.currentBytes = offset; this.publish(false)
        if (offset >= item.size) { item.state = 'uploaded'; this.changed(job.destination); return }
      }
    } finally {
      if (source) { fileIo.closeSync(source) }
      this.staged = ''; StorageBudget.removeWhenUnused(path); StorageBudget.unpin(path)
    }
  }
  private async run(job: AlbumUploadJob): Promise<void> {
    try {
      if (!this.runnable(job)) { return }
      job.state = 'checking'; await this.store.save(job); this.publish()
      if (!await this.indexRemote(job)) { return }
      while (this.runnable(job)) {
        const item = await this.store.next(job.id)
        if (!item) {
          job.state = job.failed > 0 ? 'failed' : 'completed'
          job.error = job.failed > 0 ? '部分图片上传失败，可重试失败项或查看明细' : ''
          return
        }
        job.state = 'running'; job.currentName = item.name; job.currentSize = item.size; job.currentBytes = 0
        item.state = 'active'; await this.store.update(item); this.publish(false)
        try {
          if (await this.target(job, item)) { item.state = 'skipped' }
          else { await this.upload(job, item) }
        } catch (error) {
          if (error instanceof UgreenError && error.kind === UgreenErrorKind.NAS_UNAVAILABLE) {
            job.state = 'waiting_server'; item.state = 'pending'; return
          }
          if (error instanceof UgreenError && (error.kind === UgreenErrorKind.AUTH_EXPIRED ||
            error.kind === UgreenErrorKind.LOGIN_FAILED)) {
            job.state = 'paused'; job.error = '登录已失效，请重新登录后继续'; item.state = 'pending'; return
          }
          if (!this.ready || !TransferBackgroundManager.shared().canRun() || !this.repository ||
            this.repository.cacheScopeHash() !== job.scope || String(job.state) === 'paused') {
            if (this.repository && this.repository.cacheScopeHash() !== job.scope) { job.state = 'paused' }
            item.state = 'pending'; return
          }
          item.state = 'failed'; item.error = (error as Error).message || '图片上传失败'
        } finally {
          if (item.state === 'active') { item.state = 'pending' }
          await this.store.update(item)
          if (String(item.state) === 'uploaded' || item.state === 'skipped') {
            await this.store.rememberRemote(job.id, item.targetName, item.size, false)
            await this.store.remember(job, item)
          }
          // Clear the current contribution before completed bytes enter the aggregate.
          job.currentBytes = 0; job.currentSize = 0
          await this.store.recount(job); this.publish(false)
        }
      }
    } catch (error) {
      if (error instanceof UgreenError && error.kind === UgreenErrorKind.NAS_UNAVAILABLE) { job.state = 'waiting_server' }
      else if (this.ready && TransferBackgroundManager.shared().canRun() && job.state !== 'paused') {
        job.state = 'failed'; job.error = (error as Error).message || '无法读取 NAS 目标文件夹'
      } else { job.state = 'paused' }
    } finally {
      job.currentName = ''; job.currentBytes = 0; job.currentSize = 0
      await this.store.save(job)
    }
  }
  private publish(force: boolean = true): void {
    if (!force && Date.now() - this.publishedAt < 700) { return }
    this.publishedAt = Date.now()
    const jobs = this.snapshot()
    TransferBackgroundManager.shared().update('album', jobs.map((job: AlbumUploadJob): TransferProgress => {
      const value = new TransferProgress()
      value.id = job.id; value.direction = 'upload'; value.bytes = job.bytes
      value.count = job.total; value.done = job.uploaded + job.skipped
      value.skipped = job.skipped; value.failed = job.failed
      value.doneBytes = job.completedBytes + job.currentBytes
      value.state = this.ready ? job.state : 'cancelled'
      value.pending = AlbumUploadPolicy.canRun(job.state)
      value.active = this.ready && value.pending && this.network !== null && this.network.isUnmetered() &&
        NasConnection.shared().canRequest()
      return value
    }))
    this.listener(jobs.slice())
  }
  private snapshotForLog(): string[] {
    return this.jobs.slice(0, 5).map((job: AlbumUploadJob): string =>
      'state=' + job.state + ' total=' + job.total.toString() + ' uploaded=' + job.uploaded.toString() +
      ' skipped=' + job.skipped.toString() + ' failed=' + job.failed.toString())
  }
}

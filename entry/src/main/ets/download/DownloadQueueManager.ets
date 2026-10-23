import { Context } from '@kit.AbilityKit'
import { fileIo } from '@kit.CoreFileKit'
import { preferences } from '@kit.ArkData'
import { DownloadDestination } from './DownloadDestination'
import { StorageBudget } from './StorageBudget'
import { DownloadDescriptor, DownloadTaskRecord, DownloadTaskStatus, FileEntry } from '../model/FileEntry'
import { BinaryDownloadProgress, HttpTransport, StreamDownloadResult } from '../core/network/HttpTransport'
import { NetworkClass, NetworkPolicy } from '../core/network/NetworkPolicy'
import { NasConnection, NasConnectionState } from '../core/network/NasConnection'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'
import { UgreenRemoteRepository } from '../repository/UgreenRemoteRepository'
import { TransferBackgroundManager } from '../transfer/TransferBackgroundManager'
import { TransferProgress } from '../transfer/TransferProgress'

export type DownloadQueueListener = (tasks: DownloadTaskRecord[], speedBytesPerSecond: number) => void
type PauseReason = 'none' | 'user' | 'network' | 'server' | 'logout' | 'background'

/**
 * Persistent, serial user-download queue.
 *
 * This is intentionally separate from DownloadManager/CacheManager. A cache
 * can be reclaimed at any time; a user download keeps its .part file and
 * metadata until it is completed or removed by the user.
 *
 * The project transport already implements streaming HTTP, Range requests and
 * a response-code fallback for NAS gateways that do not honor Range. Keeping
 * that implementation here also works on HarmonyOS versions whose ArkTS kit
 * still exposes only the legacy request type declarations.
 */
export class DownloadQueueManager {
  private static readonly PREFERENCES_NAME: string = 'ugreen-network-settings'
  private static readonly TASKS_KEY: string = 'download_tasks_v1'
  private static readonly MOBILE_CONTINUE_KEY: string = 'metered_download_continue'
  private static readonly PERSIST_DELAY_MS: number = 250
  private context: Context | null = null
  private repository: UgreenRemoteRepository | null = null
  private networkPolicy: NetworkPolicy | null = null
  private preferencesStore: preferences.Preferences | null = null
  private transport: HttpTransport = new HttpTransport()
  private tasks: DownloadTaskRecord[] = []
  private listeners: DownloadQueueListener[] = []
  private initialized: boolean = false
  private ready: boolean = false
  private meteredDownloadContinue: boolean = false
  private removedIds: Set<string> = new Set<string>()
  private activeRecordId: string = ''
  private activePauseReason: PauseReason = 'none'
  private activeStartBytes: number = 0
  private activeLastBytes: number = 0
  private activeLastAt: number = 0
  private speedBytesPerSecond: number = 0
  private scheduleInFlight: boolean = false
  private scheduleAgain: boolean = false
  private persistTimer: number = 0
  private stagingDirectory: string = ''
  private networkListener = (state: NetworkClass): void => {
    this.handleNetworkState(state)
  }

  async initialize(context: Context, repository: UgreenRemoteRepository,
    networkPolicy: NetworkPolicy): Promise<void> {
    if (this.initialized) {
      this.context = context
      this.repository = repository
      this.networkPolicy = networkPolicy
      return
    }
    this.context = context
    DownloadDestination.initialize(context)
    this.repository = repository
    this.networkPolicy = networkPolicy
    this.stagingDirectory = context.filesDir + '/ugreen-download-tasks'
    this.ensureDirectory(this.stagingDirectory)
    try {
      this.preferencesStore = await preferences.getPreferences(context, DownloadQueueManager.PREFERENCES_NAME)
      const storedContinue = await this.preferencesStore.get(
        DownloadQueueManager.MOBILE_CONTINUE_KEY, false)
      if (typeof storedContinue === 'boolean') {
        this.meteredDownloadContinue = storedContinue
      }
      const storedTasks = await this.preferencesStore.get(DownloadQueueManager.TASKS_KEY, '[]')
      if (typeof storedTasks === 'string') {
        this.loadTasks(storedTasks)
      }
    } catch (error) {
      console.warn('[UgreenDownload] preferences unavailable: ' + JSON.stringify(error))
    }
    StorageBudget.onEvicted((path: string): void => {
      for (const task of this.tasks) {
        if (task.stagingPath === path && task.status !== 'completed') {
          task.receivedBytes = 0
          task.status = 'paused'
          task.errorMessage = '临时缓存已回收，继续时将重新下载'
        }
      }
      this.requestPersist()
      this.notify()
    })
    this.pruneHistory()
    this.reconcileStaging()
    this.initialized = true
    networkPolicy.onChange(this.networkListener)
    NasConnection.shared().onChange((state: NasConnectionState): void => this.handleNasState(state))
    TransferBackgroundManager.shared().onChange(() => { this.schedule() })
    TransferBackgroundManager.shared().onCancel(() => {
      this.activePauseReason = 'user'
      for (const task of this.tasks) {
        if (task.status === 'queued' || task.status === 'downloading') { task.status = 'paused' }
      }
      this.requestPersist(); this.notify()
    })
    this.notify()
  }

  onChange(listener: DownloadQueueListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  snapshot(): DownloadTaskRecord[] {
    return this.tasks.map((task: DownloadTaskRecord): DownloadTaskRecord => this.copyTask(task))
  }

  speed(): number {
    return this.speedBytesPerSecond
  }

  async setReady(ready: boolean): Promise<void> {
    this.ready = ready
    if (!ready) {
      this.activePauseReason = 'logout'
      const active = this.activeRecord()
      if (active !== null && active.status === 'downloading') {
        active.status = 'paused'
        active.errorMessage = ''
        active.updatedAt = Date.now()
      }
      this.speedBytesPerSecond = 0
      this.requestPersist()
      this.notify()
      return
    }
    if (this.initialized) {
      this.activePauseReason = 'none'
      this.schedule()
    }
  }

  async setMeteredDownloadContinue(value: boolean): Promise<void> {
    this.meteredDownloadContinue = value
    if (this.preferencesStore !== null) {
      try {
        await this.preferencesStore.put(DownloadQueueManager.MOBILE_CONTINUE_KEY, value)
        await this.preferencesStore.flush()
      } catch (error) {
        console.warn('[UgreenDownload] setting persist failed: ' + JSON.stringify(error))
      }
    }
    if (!value && this.isMeteredNetwork()) {
      const active = this.activeRecord()
      if (active !== null && active.status === 'downloading') {
        active.manualMobileResume = false
      }
      this.pauseActiveForNetwork()
    }
    this.schedule()
  }

  async enqueue(entry: FileEntry, destinationRoot: string = '', relativePath: string = ''): Promise<string> {
    if (!this.initialized || this.context === null) {
      throw new Error('下载服务尚未初始化')
    }
    if (entry.isDirectory || entry.path.length === 0) {
      throw new Error('目录不能加入下载')
    }
    const normalizedRoot = destinationRoot.replace(/[\\/]$/, '')
    const normalizedRelative = relativePath.length > 0 ? this.safeRelativePath(relativePath) : entry.name
    for (const existing of this.tasks) {
      if (existing.remotePath === entry.path && existing.destinationRoot === normalizedRoot &&
        existing.relativePath === normalizedRelative && existing.status !== 'failed') {
        return existing.id
      }
    }
    const now = Date.now()
    const scope = this.repository?.cacheScopeHash() ?? ''
    await DownloadDestination.directory()
    await TransferBackgroundManager.shared().requestResume()
    if (!this.ready || scope !== (this.repository?.cacheScopeHash() ?? '')) {
      throw new Error('账号已变化，请重新发起下载')
    }
    const task = new DownloadTaskRecord()
    task.id = now.toString() + '-' + Math.floor(Math.random() * 1000000).toString()
    task.remotePath = entry.path
    task.name = entry.name
    task.mimeType = entry.mimeType
    task.size = Math.max(0, entry.size)
    task.status = 'queued'
    task.createdAt = now
    task.updatedAt = now
    task.stagingPath = this.stagingDirectory + '/' + task.id + '.part'
    task.destinationRoot = normalizedRoot
    task.relativePath = normalizedRelative
    task.manualMobileResume = this.isMeteredNetwork()
    // Keep the queue record tied to the same remote version used by the
    // video/cache resolver. Older callers may not supply validators.
    if (this.repository !== null) {
      const signature = this.repository.signatureForFile(entry)
      task.sourceKey = signature.key()
      task.sourceEtag = signature.etag
      task.sourceChecksum = signature.checksum
    }
    this.tasks.push(task)
    this.requestPersist()
    this.notify()
    this.schedule()
    return task.id
  }

  async toggleTask(id: string): Promise<boolean> {
    const task = this.findTask(id)
    if (task === null || task.status === 'completed') {
      return true
    }
    if (task.status === 'downloading') {
      if (this.activeRecordId !== id) {
        return false
      }
      this.pauseActiveByUser()
      return true
    }
    if (!this.isQueueHead(task)) {
      return false
    }
    const scope = this.repository?.cacheScopeHash() ?? ''
    await DownloadDestination.directory()
    await TransferBackgroundManager.shared().requestResume()
    if (!this.ready || this.findTask(id) !== task || scope !== (this.repository?.cacheScopeHash() ?? '')) {
      return false
    }
    if (task.status === 'waiting_server') {
      await NasConnection.shared().retryNow()
      this.schedule()
      return true
    }
    if (task.status === 'failed') {
      task.errorMessage = ''
      task.status = 'queued'
    } else if (task.status === 'paused' || task.status === 'waiting_wifi') {
      task.status = 'queued'
    }
    if (this.isMeteredNetwork()) {
      // An explicit tap is allowed to start/resume on mobile data without a
      // confirmation dialog.
      task.manualMobileResume = true
    }
    task.updatedAt = Date.now()
    this.requestPersist()
    this.notify()
    this.schedule()
    return true
  }

  async removeRecord(id: string): Promise<void> {
    const task = this.findTask(id)
    if (task === null) {
      return
    }
    if (this.activeRecordId === id) {
      this.removedIds.add(id)
      this.activePauseReason = 'user'
      task.status = 'paused'
      this.speedBytesPerSecond = 0
    } else {
      this.removeFile(task.stagingPath)
    }
    this.tasks = this.tasks.filter((item: DownloadTaskRecord): boolean => item.id !== id)
    this.requestPersist()
    this.notify()
    this.schedule()
  }

  private loadTasks(json: string): void {
    try {
      const parsed = JSON.parse(json) as DownloadTaskRecord[]
      if (!(parsed instanceof Array)) {
        return
      }
      const result: DownloadTaskRecord[] = []
      for (const item of parsed) {
        const source = item as DownloadTaskRecord
        if (source.id === undefined || source.remotePath === undefined || source.name === undefined) {
          continue
        }
        const task = new DownloadTaskRecord()
        task.id = source.id
        task.remotePath = source.remotePath
        task.name = source.name
        task.mimeType = typeof source.mimeType === 'string' ? source.mimeType : ''
        task.size = typeof source.size === 'number' ? Math.max(0, source.size) : 0
        task.receivedBytes = typeof source.receivedBytes === 'number'
          ? Math.max(0, source.receivedBytes) : 0
        task.status = this.normalizeStatus(source.status)
        task.createdAt = typeof source.createdAt === 'number' ? source.createdAt : Date.now()
        task.updatedAt = typeof source.updatedAt === 'number' ? source.updatedAt : task.createdAt
        task.stagingPath = typeof source.stagingPath === 'string' && source.stagingPath.length > 0
          ? source.stagingPath : this.stagingDirectory + '/' + task.id + '.part'
        task.finalPath = typeof source.finalPath === 'string' ? source.finalPath : ''
        task.destinationRoot = typeof source.destinationRoot === 'string' ? source.destinationRoot : ''
        task.relativePath = typeof source.relativePath === 'string' && source.relativePath.length > 0
          ? this.safeRelativePath(source.relativePath) : task.name
        // System task IDs from an earlier implementation are not valid for
        // the streaming transport; resume from the persistent .part instead.
        task.systemTaskId = ''
        task.errorMessage = typeof source.errorMessage === 'string' ? source.errorMessage : ''
        task.manualMobileResume = source.manualMobileResume === true
        task.sourceKey = typeof source.sourceKey === 'string' ? source.sourceKey : ''
        task.sourceEtag = typeof source.sourceEtag === 'string' ? source.sourceEtag : ''
        task.sourceChecksum = typeof source.sourceChecksum === 'string' ? source.sourceChecksum : ''
        if (task.status === 'downloading') {
          task.status = 'queued'
        }
        result.push(task)
      }
      this.tasks = result
    } catch (error) {
      console.warn('[UgreenDownload] task state parse failed: ' + JSON.stringify(error))
    }
  }

  private pruneHistory(): void {
    const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000
    const completed = this.tasks.filter((task: DownloadTaskRecord): boolean => task.status === 'completed')
      .sort((a: DownloadTaskRecord, b: DownloadTaskRecord): number => b.updatedAt - a.updatedAt)
      .filter((task: DownloadTaskRecord): boolean => task.updatedAt >= cutoff).slice(0, 200)
    this.tasks = this.tasks.filter((task: DownloadTaskRecord): boolean =>
      task.status !== 'completed' || completed.indexOf(task) >= 0)
    this.requestPersist()
  }

  private reconcileStaging(): void {
    // This directory belongs only to this queue. Video account stores use a different root.
    const owned = this.tasks.filter((task: DownloadTaskRecord): boolean => task.status !== 'completed')
      .map((task: DownloadTaskRecord): string => task.stagingPath)
    for (const name of fileIo.listFileSync(this.stagingDirectory)) {
      const path = this.stagingDirectory + '/' + name
      if (name.endsWith('.part.incoming') || (owned.indexOf(path) < 0 && name.endsWith('.part'))) {
        this.removeFile(path)
      }
    }
    for (const task of this.tasks) {
      if (task.status !== 'completed') { task.receivedBytes = this.fileSize(task.stagingPath) }
    }
  }

  private normalizeStatus(status: DownloadTaskStatus): DownloadTaskStatus {
    if (status === 'queued' || status === 'downloading' || status === 'paused' ||
      status === 'waiting_wifi' || status === 'waiting_server' || status === 'completed' || status === 'failed') {
      return status
    }
    return 'queued'
  }

  private handleNetworkState(state: NetworkClass): void {
    if (state === 'unmetered') {
      for (const task of this.tasks) {
        if (task.status !== 'completed') {
          task.manualMobileResume = false
        }
      }
      const active = this.activeRecord()
      if (active !== null && active.status === 'waiting_wifi') {
        active.status = 'queued'
        active.errorMessage = ''
        active.updatedAt = Date.now()
      }
      if (this.activePauseReason === 'network') { this.activePauseReason = 'none' }
      this.requestPersist()
      this.notify()
      this.schedule()
      return
    }
    if (state === 'metered' || state === 'unknown') {
      if (!this.meteredDownloadContinue) {
        this.pauseActiveForNetwork()
      }
      this.schedule()
      return
    }
    if (state === 'offline') {
      this.pauseActiveForNetwork()
    }
  }

  private pauseActiveForNetwork(): void {
    const active = this.activeRecord()
    if (active === null || active.status !== 'downloading' || active.manualMobileResume) {
      return
    }
    this.activePauseReason = 'network'
    active.status = 'waiting_wifi'
    active.updatedAt = Date.now()
    active.errorMessage = ''
    this.speedBytesPerSecond = 0
    this.requestPersist()
    this.notify()
  }

  private handleNasState(state: NasConnectionState): void {
    if (state === 'online') {
      for (const task of this.tasks) {
        if (task.status === 'waiting_server') { task.status = 'queued'; task.errorMessage = '' }
      }
      this.schedule()
    } else if (state === 'unavailable' || state === 'connecting') {
      for (const task of this.tasks) {
        if (task.status === 'queued' || task.status === 'downloading') {
          if (task.id === this.activeRecordId) { this.activePauseReason = 'server' }
          task.status = 'waiting_server'
          task.errorMessage = ''
          task.updatedAt = Date.now()
        }
      }
      this.speedBytesPerSecond = 0
    }
    this.requestPersist()
    this.notify()
  }

  private pauseActiveByUser(): void {
    const active = this.activeRecord()
    if (active === null) {
      return
    }
    this.activePauseReason = 'user'
    active.status = 'paused'
    active.manualMobileResume = false
    active.updatedAt = Date.now()
    active.errorMessage = ''
    this.speedBytesPerSecond = 0
    this.requestPersist()
    this.notify()
  }

  private schedule(): void {
    if (this.scheduleInFlight) {
      this.scheduleAgain = true
      return
    }
    this.scheduleInFlight = true
    this.runScheduler().catch((error: Object): void => {
      console.warn('[UgreenDownload] scheduler failed: ' + JSON.stringify(error))
    }).finally((): void => {
      this.scheduleInFlight = false
      if (this.scheduleAgain) {
        this.scheduleAgain = false
        this.schedule()
      }
    })
  }

  private async runScheduler(): Promise<void> {
    if (!this.ready || !this.initialized || this.context === null || this.repository === null) {
      return
    }
    if (this.activeRecordId.length > 0) {
      return
    }
    if (!TransferBackgroundManager.shared().canRun()) { this.notify(); return }
    const head = this.queueHead()
    if (head === null || head.status === 'paused' || head.status === 'failed') {
      return
    }
    if (!this.canStart(head)) {
      if (head.status === 'queued') {
        head.status = NasConnection.shared().canRequest() ? 'waiting_wifi' : 'waiting_server'
        head.updatedAt = Date.now()
        this.requestPersist()
        this.notify()
      }
      return
    }
    await this.startDownload(head)
  }

  private canStart(task: DownloadTaskRecord): boolean {
    if (!NasConnection.shared().canRequest()) { return false }
    const state = this.networkPolicy === null ? 'unknown' : this.networkPolicy.current()
    if (state === 'offline') {
      return false
    }
    if (state === 'unmetered') {
      return true
    }
    return this.meteredDownloadContinue || task.manualMobileResume
  }

  private async startDownload(record: DownloadTaskRecord): Promise<void> {
    if (this.repository === null) {
      return
    }
    this.activeRecordId = record.id
    this.activePauseReason = 'none'
    StorageBudget.pin(record.stagingPath)
    try {
      await this.runDownload(record)
    } finally {
      StorageBudget.unpin(record.stagingPath)
      if (this.removedIds.has(record.id)) {
        this.removeFile(record.stagingPath)
        this.removedIds.delete(record.id)
      }
      if (this.activeRecordId === record.id) { this.activeRecordId = '' }
      this.activePauseReason = 'none'
      this.schedule()
    }
  }

  private async runDownload(record: DownloadTaskRecord): Promise<void> {
    if (this.repository === null) { return }
    const stageSize = this.fileSize(record.stagingPath)
    if (record.size > 0 && stageSize > record.size) {
      this.removeFile(record.stagingPath)
      record.receivedBytes = 0
    } else {
      record.receivedBytes = stageSize
    }
    if (record.size > 0 && record.receivedBytes === record.size) {
      await this.finalizeRecord(record)
      return
    }
    try {
      const descriptor = await this.repository.downloadDescriptor(record.remotePath)
      if (this.removedIds.has(record.id) || this.activePauseReason === 'user') { return }
      if (descriptor.size > 0) {
        record.size = descriptor.size
      }
      if (descriptor.etag.length > 0) {
        record.sourceEtag = descriptor.etag
      }
      if (descriptor.checksum.length > 0) {
        record.sourceChecksum = descriptor.checksum
      }
      if (descriptor.fileName.length > 0 && record.name.length === 0) {
        record.name = descriptor.fileName
      }
      // The token request is asynchronous. Re-check the network policy after
      // it returns so a WiFi→mobile transition during token acquisition does
      // not turn a policy pause into a false download failure.
      if (!this.ready) {
        record.status = 'paused'
        record.updatedAt = Date.now()
        return
      }
      if (!TransferBackgroundManager.shared().canRun()) {
        record.status = 'queued'
        record.updatedAt = Date.now()
        this.requestPersist(); this.notify()
        return
      }
      if (!this.canStart(record)) {
        record.status = NasConnection.shared().canRequest() ? 'waiting_wifi' : 'waiting_server'
        record.updatedAt = Date.now()
        this.requestPersist()
        this.notify()
        return
      }
      this.activeRecordId = record.id
      this.activePauseReason = 'none'
      this.activeStartBytes = record.receivedBytes
      this.activeLastBytes = record.receivedBytes
      this.activeLastAt = Date.now()
      this.speedBytesPerSecond = 0
      record.status = 'downloading'
      record.errorMessage = ''
      record.updatedAt = Date.now()
      this.requestPersist()
      this.notify()

      const result = await this.streamWithResumeFallback(record, descriptor, record.receivedBytes)
      if (result.totalSize > 0) {
        record.size = Math.max(record.size, result.totalSize)
      }
      record.receivedBytes = this.fileSize(record.stagingPath)
      if (this.activePauseReason !== 'none') {
        // The stream stopped because the user/network policy asked it to.
        return
      }
      if (record.size > 0 && record.receivedBytes !== record.size) {
        throw new Error('文件下载不完整')
      }
      await this.finalizeRecord(record)
    } catch (error) {
      if (error instanceof UgreenError && error.kind === UgreenErrorKind.NAS_UNAVAILABLE &&
        record.status !== 'paused' && this.activePauseReason !== 'user') {
        record.status = 'waiting_server'
        record.receivedBytes = this.fileSize(record.stagingPath)
      }
      if (record.status === 'paused' || record.status === 'waiting_wifi' || record.status === 'waiting_server' ||
        this.activePauseReason !== 'none') {
        record.errorMessage = ''
        this.requestPersist()
        this.notify()
      } else {
        record.status = 'failed'
        record.errorMessage = this.errorMessage(error)
        record.updatedAt = Date.now()
        this.requestPersist()
        this.notify()
      }
    } finally {
      // startDownload owns the active slot until all file handles are closed.
      this.speedBytesPerSecond = 0
      this.requestPersist()
      this.notify()
      this.schedule()
    }
  }

  private async streamWithResumeFallback(record: DownloadTaskRecord,
    descriptor: DownloadDescriptor, offset: number): Promise<StreamDownloadResult> {
    try {
      return await this.streamDownload(record, descriptor, offset)
    } catch (error) {
      if (offset <= 0 || !this.isResumeRejected(error as Object) ||
        record.status !== 'downloading') {
        throw error as Error
      }
      // Some NAS firmware returns 206/416 for a stale range. Retry once from
      // zero; this never discards the partial file for a normal pause/network
      // transition because those use status paused/waiting_wifi.
      this.removeFile(record.stagingPath)
      record.receivedBytes = 0
      record.updatedAt = Date.now()
      const fresh = this.repository === null
        ? descriptor : await this.repository.downloadDescriptor(record.remotePath)
      if (fresh.size > 0) {
        record.size = fresh.size
      }
      return await this.streamDownload(record, fresh, 0)
    }
  }

  private async streamDownload(record: DownloadTaskRecord, descriptor: DownloadDescriptor,
    offset: number): Promise<StreamDownloadResult> {
    return await this.transport.requestBinaryToFile(descriptor.url, record.stagingPath,
      descriptor.headers, offset, record.size, (progress: BinaryDownloadProgress): void => {
        this.updateProgress(record, progress)
      }, (): boolean => this.shouldContinueActive(record))
  }

  private shouldContinueActive(record: DownloadTaskRecord): boolean {
    if (!TransferBackgroundManager.shared().canRun()) {
      this.activePauseReason = 'background'; record.status = 'queued'
      this.requestPersist(); this.notify(); return false
    }
    if (!this.ready) {
      this.activePauseReason = 'logout'
      record.status = 'paused'
      record.updatedAt = Date.now()
      return false
    }
    if (this.activeRecordId !== record.id || record.status !== 'downloading') {
      return false
    }
    if (this.activePauseReason !== 'none') {
      return false
    }
    if (!NasConnection.shared().canRequest()) {
      this.handleNasState('unavailable')
      return false
    }
    if (this.networkPolicy === null) {
      return false
    }
    const state = this.networkPolicy.current()
    if (state === 'offline') {
      this.pauseActiveForNetwork()
      return false
    }
    if (state === 'unmetered') {
      return true
    }
    if (this.meteredDownloadContinue || record.manualMobileResume) {
      return true
    }
    this.pauseActiveForNetwork()
    return false
  }

  private updateProgress(record: DownloadTaskRecord, progress: BinaryDownloadProgress): void {
    if (this.activeRecordId !== record.id) {
      return
    }
    const received = Math.max(progress.receiveSize, this.fileSize(record.stagingPath))
    if (progress.totalSize > 0) {
      record.size = Math.max(record.size, progress.totalSize)
    }
    const now = Date.now()
    if (now > this.activeLastAt && received >= this.activeLastBytes) {
      const instantaneous = (received - this.activeLastBytes) * 1000 / (now - this.activeLastAt)
      this.speedBytesPerSecond = this.speedBytesPerSecond <= 0
        ? instantaneous : this.speedBytesPerSecond * 0.7 + instantaneous * 0.3
    }
    this.activeLastAt = now
    this.activeLastBytes = received
    record.receivedBytes = received
    record.updatedAt = now
    this.requestPersist()
    this.notify()
  }

  private async finalizeRecord(record: DownloadTaskRecord): Promise<void> {
    const actualSize = this.fileSize(record.stagingPath)
    if (record.size > 0 && actualSize !== record.size) {
      record.receivedBytes = actualSize
      record.status = 'failed'
      record.errorMessage = '文件下载不完整，可点击重试'
      record.updatedAt = Date.now()
      this.requestPersist()
      this.notify()
      return
    }
    try {
      const finalPath = await DownloadDestination.save(record.stagingPath,
        record.relativePath.length > 0 ? record.relativePath : record.name)
      record.finalPath = finalPath
      record.receivedBytes = record.size > 0 ? record.size : actualSize
      if (record.size <= 0) {
        record.size = record.receivedBytes
      }
      record.status = 'completed'
      record.errorMessage = ''
      record.updatedAt = Date.now()
      record.manualMobileResume = false
      await this.persist()
      await DownloadDestination.acknowledge(record.stagingPath)
      this.pruneHistory()
      this.requestPersist()
      this.notify()
    } catch (error) {
      record.status = 'failed'
      record.errorMessage = this.errorMessage(error, '文件已接收，保存到系统下载目录失败，可重试')
      record.updatedAt = Date.now()
      this.requestPersist()
      this.notify()
    }
  }

  private queueHead(): DownloadTaskRecord | null {
    for (const task of this.tasks) {
      if (task.status !== 'completed') {
        return task
      }
    }
    return null
  }

  private isQueueHead(task: DownloadTaskRecord): boolean {
    const head = this.queueHead()
    return head !== null && head.id === task.id
  }

  private findTask(id: string): DownloadTaskRecord | null {
    for (const task of this.tasks) {
      if (task.id === id) {
        return task
      }
    }
    return null
  }

  private activeRecord(): DownloadTaskRecord | null {
    return this.activeRecordId.length === 0 ? null : this.findTask(this.activeRecordId)
  }

  private isMeteredNetwork(): boolean {
    return this.networkPolicy === null ? true : this.networkPolicy.isMetered()
  }

  private requestPersist(): void {
    if (this.persistTimer > 0) {
      return
    }
    this.persistTimer = setTimeout((): void => {
      this.persistTimer = 0
      this.persist().catch((error: Object): void => {
        console.warn('[UgreenDownload] persist failed: ' + JSON.stringify(error))
      })
    }, DownloadQueueManager.PERSIST_DELAY_MS)
  }

  private async persist(): Promise<void> {
    if (this.preferencesStore === null) {
      throw new Error('本地存储未就绪，无法保存下载记录')
    }
    await this.preferencesStore.put(DownloadQueueManager.TASKS_KEY, JSON.stringify(this.tasks))
    await this.preferencesStore.flush()
  }

  private notify(): void {
    const head = this.queueHead()
    TransferBackgroundManager.shared().update('download', this.tasks.map((task: DownloadTaskRecord): TransferProgress => {
      const value = new TransferProgress()
      value.id = task.id; value.direction = 'download'; value.bytes = task.size
      value.doneBytes = task.status === 'completed' ? task.size : task.receivedBytes
      value.done = task.status === 'completed' ? 1 : 0
      value.failed = task.status === 'failed' ? 1 : 0
      value.state = this.ready ? task.status : 'cancelled'
      value.pending = task.status === 'queued' || task.status === 'downloading'
      value.active = this.ready && value.pending && head !== null && head.id === task.id && this.canStart(task)
      return value
    }))
    const snapshot = this.snapshot()
    for (const listener of this.listeners.slice()) {
      try {
        listener(snapshot, this.speedBytesPerSecond)
      } catch (error) {
        console.warn('[UgreenDownload] listener failed: ' + JSON.stringify(error))
      }
    }
  }

  private copyTask(source: DownloadTaskRecord): DownloadTaskRecord {
    const result = new DownloadTaskRecord()
    DownloadTaskRecord.copyInto(source, result)
    return result
  }

  private ensureDirectory(path: string): void {
    try {
      fileIo.mkdirSync(path, true)
    } catch (_) {
      // It already exists or will be reported by finalizeRecord.
    }
  }

  private fileSize(path: string): number {
    if (path.length === 0) {
      return 0
    }
    try {
      return fileIo.statSync(path).size
    } catch (_) {
      return 0
    }
  }

  private removeFile(path: string): void {
    if (path.length === 0) {
      return
    }
    try {
      fileIo.unlinkSync(path)
      StorageBudget.sync(path)
    } catch (_) {
      // The file may already have been removed.
    }
  }

  private uniqueFinalPath(directory: string, originalName: string): string {
    const safeName = this.safeFileName(originalName)
    let candidate = directory + '/' + safeName
    let suffix = 1
    while (this.fileExists(candidate)) {
      const dot = safeName.lastIndexOf('.')
      const stem = dot > 0 ? safeName.substring(0, dot) : safeName
      const extension = dot > 0 ? safeName.substring(dot) : ''
      candidate = directory + '/' + stem + ' (' + suffix.toString() + ')' + extension
      suffix += 1
    }
    return candidate
  }

  private safeRelativePath(path: string): string {
    const parts = path.split(/[\\/]+/)
    const safeParts: string[] = []
    for (const part of parts) {
      const trimmed = part.trim()
      if (trimmed.length === 0 || trimmed === '.' || trimmed === '..') {
        continue
      }
      safeParts.push(this.safeFileName(trimmed))
    }
    return safeParts.join('/')
  }

  private fileExists(path: string): boolean {
    try {
      fileIo.statSync(path)
      return true
    } catch (_) {
      return false
    }
  }

  private safeFileName(name: string): string {
    const normalized = name.trim().replace(/[\\/:*?"<>|]/g, '_')
    return normalized.length > 0 ? normalized : 'download'
  }

  private isResumeRejected(error: Object): boolean {
    if (error instanceof UgreenError) {
      return error.status === 206 || error.status === 416
    }
    return false
  }

  private errorMessage(error: Object, fallback: string = '下载失败'): string {
    if (error instanceof UgreenError && error.message.length > 0) {
      return error.message
    }
    const value = error as Record<string, Object>
    const message = value['message']
    if (typeof message === 'string' && message.length > 0) {
      return message
    }
    return fallback
  }
}

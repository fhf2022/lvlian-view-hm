import { common, wantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import { preferences } from '@kit.ArkData'
import { BusinessError } from '@kit.BasicServicesKit'
import { TransferProgress, summarizeTransfers } from './TransferProgress'
import { NasConnection } from '../core/network/NasConnection'

/** One system-owned data-transfer notification; all queues publish bounded snapshots.
 * The system LIVE_VIEW slot below belongs to Background Tasks Kit. It must keep
 * receiving progress; no Live View Kit entitlement or custom capsule is used.
 */
export class TransferBackgroundManager {
  private static instance: TransferBackgroundManager = new TransferBackgroundManager()
  static shared(): TransferBackgroundManager { return TransferBackgroundManager.instance }
  private context: common.UIAbilityContext | null = null
  private foreground: boolean = true
  private sources: Map<string, TransferProgress[]> = new Map()
  private session: Map<string, TransferProgress> = new Map()
  private taskId: number = -1
  private notificationId: number = -1
  private healthy: boolean = false
  private attempted: boolean = false
  private blocked: boolean = false
  private notificationRequested: boolean = false
  private notificationRequest: Promise<void> | null = null
  private destroyed: boolean = false
  private cleanup: Promise<void> | null = null
  private queue: Promise<void> = Promise.resolve()
  private queued: boolean = false
  private timer: number = 0
  private lastPublished: number = 0
  private listeners: (() => void)[] = []
  private cancelListeners: (() => void)[] = []
  private cancel = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (info.id !== this.taskId) { return }
    this.taskId = -1; this.notificationId = -1; this.healthy = false
    this.blocked = true; this.attempted = true
    this.status('后台传输保护已停止，点击任务可继续')
    console.info('[TransferProtection] cancelled reason=' + info.reason.toString())
    for (const listener of this.cancelListeners.slice()) { listener() }
    this.changed()
  }

  initialize(context: common.UIAbilityContext): void {
    if (this.destroyed && this.cleanup) {
      this.cleanup.then((): void => { this.initialize(context) })
      return
    }
    if (this.context) { return }
    this.context = context; this.destroyed = false; this.foreground = true
    this.attempted = false; this.blocked = false
    this.status('')
    notificationManager.isNotificationEnabled().then((enabled: boolean): void => {
      console.info('[TransferProtection] notification-enabled=' + enabled.toString())
    }).catch((error: Object): void => {
      console.warn('[TransferProtection] notification check failed ' + JSON.stringify(error))
    })
    notificationManager.getSlots().then((slots: notificationManager.NotificationSlot[]): void => {
      const live = slots.find((slot: notificationManager.NotificationSlot): boolean =>
        slot.notificationType === notificationManager.SlotType.LIVE_VIEW)
      console.info('[TransferProtection] live-view-slot-enabled=' + (live?.enabled ?? true).toString())
    }).catch(() => {})
    try { backgroundTaskManager.on('continuousTaskCancel', this.cancel) }
    catch (error) { console.warn('[TransferProtection] cancel subscription failed ' + JSON.stringify(error)) }
  }
  onChange(listener: () => void): void { this.listeners.push(listener) }
  onCancel(listener: () => void): void { this.cancelListeners.push(listener) }
  isForeground(): boolean { return this.foreground }
  canRun(): boolean { return !this.destroyed && (this.foreground || this.healthy) }
  async requestResume(): Promise<void> {
    await this.requestNotificationPermission()
    this.blocked = false; this.attempted = false
    this.schedule()
  }
  // Called after loadContent completes, and shared with explicit transfer actions.
  async requestNotificationPermission(): Promise<void> {
    if (this.context && this.foreground && !this.destroyed) {
      if (!this.notificationRequest) {
        this.notificationRequest = this.authorizeNotifications().finally((): void => { this.notificationRequest = null })
      }
      await this.notificationRequest
    }
  }
  private async notificationsAvailable(): Promise<boolean> {
    if (!await notificationManager.isNotificationEnabled()) { return false }
    const slots = await notificationManager.getSlots()
    const live = slots.find((slot: notificationManager.NotificationSlot): boolean =>
      slot.notificationType === notificationManager.SlotType.LIVE_VIEW)
    return live?.enabled !== false
  }
  private async authorizeNotifications(): Promise<void> {
    try {
      if (this.context) {
        const context = this.context
        const store = await preferences.getPreferences(context, 'ugreen-system-permissions')
        const requested = await store.get('notification_permission_requested_v1', false)
        if (!await notificationManager.isNotificationEnabled() && requested !== true && !this.notificationRequested) {
          if (this.context !== context || !this.foreground || this.destroyed) { return }
          this.notificationRequested = true
          try { await notificationManager.requestEnableNotification(context) }
          catch (error) {
            if ((error as BusinessError).code !== 1600004) { this.notificationRequested = false; throw error as Error }
          }
        }
        // Persist the first-use decision, including rejection; later changes use system settings.
        await store.put('notification_permission_requested_v1', true)
        await store.flush()
      }
      const available = await this.notificationsAvailable()
      AppStorage.setOrCreate('transferNotificationBlocked', !available)
      this.status(available ? '' : '通知未开启，当前仅前台传输；开启通知后可使用后台保护')
      console.info('[TransferProtection] notification-authorized=' + available.toString())
    } catch (error) {
      AppStorage.setOrCreate('transferNotificationBlocked', true)
      this.status('通知未开启，当前仅前台传输；开启通知后可使用后台保护')
      console.warn('[TransferProtection] notification authorization failed ' + JSON.stringify(error))
    }
  }
  async openNotificationSettings(): Promise<void> {
    if (!this.context || !this.foreground || this.destroyed) { return }
    try {
      await notificationManager.openNotificationSettingsWithResult(this.context)
      await this.requestResume()
    } catch (error) {
      console.warn('[TransferProtection] notification settings failed ' + JSON.stringify(error))
    }
  }
  setForeground(value: boolean): void {
    this.foreground = value
    if (value && !this.blocked && this.taskId < 0) { this.attempted = false }
    this.changed(); this.schedule()
  }
  update(source: string, tasks: TransferProgress[]): void {
    this.sources.set(source, tasks)
    for (const task of tasks) {
      const key = source + ':' + task.id
      if (task.pending || this.session.has(key)) { this.session.set(key, task) }
    }
    for (const key of Array.from(this.session.keys())) {
      if (key.startsWith(source + ':') && !tasks.some((task: TransferProgress): boolean =>
        source + ':' + task.id === key)) {
        const previous = this.session.get(key)
        if (previous && previous.done < previous.count) {
          this.session.delete(key)
        }
      }
    }
    this.schedule()
  }
  private wanted(): boolean {
    for (const tasks of this.sources.values()) {
      if (tasks.some((task: TransferProgress): boolean => task.active)) { return true }
    }
    return false
  }
  private changed(): void { for (const listener of this.listeners.slice()) { listener() } }
  private status(error: string): void {
    NasConnection.shared().setBackgroundTransferRunning(this.healthy)
    AppStorage.setOrCreate('transferProtectionActive', this.healthy)
    AppStorage.setOrCreate('transferProtectionError', error)
  }
  private schedule(): void {
    if (this.queued || this.destroyed) { return }
    this.queued = true
    this.queue = this.queue.catch(() => {}).then(async (): Promise<void> => {
      this.queued = false
      await this.reconcile()
    }).catch((error: Object): void => {
      console.warn('[TransferProtection] update failed ' + JSON.stringify(error))
    })
  }
  private async reconcile(): Promise<void> {
    if (!this.context || this.destroyed) { return }
    if (!this.wanted()) {
      await this.stop()
      this.session.clear(); this.attempted = false
      AppStorage.setOrCreate('transferProgressText', '')
      if (!this.blocked) { this.status('') }
      return
    }
    const summary = summarizeTransfers(Array.from(this.session.values()))
    AppStorage.setOrCreate('transferProgressText', summary.text)
    if (this.taskId < 0 && !this.attempted && !this.blocked) {
      this.attempted = true
      try {
        if (!await this.notificationsAvailable()) {
          AppStorage.setOrCreate('transferNotificationBlocked', true)
          this.status('通知未开启，当前仅前台传输；开启通知后可使用后台保护')
          this.changed(); return
        }
        AppStorage.setOrCreate('transferNotificationBlocked', false)
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: this.context.abilityInfo.bundleName,
            abilityName: this.context.abilityInfo.name, parameters: { transferEntry: true } }],
          actionType: wantAgent.OperationType.START_ABILITY, requestCode: 7106,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        })
        const request = new backgroundTaskManager.ContinuousTaskRequest()
        request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER]
        request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION]
        request.wantAgent = agent; request.combinedTaskNotification = false
        const result = await backgroundTaskManager.startBackgroundRunning(this.context, request)
        if (result.continuousTaskId === undefined) { throw new Error('系统未返回传输任务标识') }
        this.taskId = result.continuousTaskId; this.notificationId = result.notificationId
        this.lastPublished = 0
        console.info('[TransferProtection] started task=' + this.taskId.toString())
      } catch (error) {
        this.healthy = false
        this.status('后台保护不可用，退后台后暂停；回到前台可继续')
        console.warn('[TransferProtection] start failed ' + JSON.stringify(error))
        this.changed(); return
      }
    }
    if (this.taskId < 0) { return }
    if (this.destroyed || !this.wanted()) { await this.stop(); return }
    const elapsed = Date.now() - this.lastPublished
    if (elapsed < 1000) {
      if (this.timer === 0) {
        this.timer = setTimeout((): void => { this.timer = 0; this.schedule() }, 1000 - elapsed)
      }
      return
    }
    try {
      const publishingTaskId = this.taskId
      const current = summarizeTransfers(Array.from(this.session.values()))
      await notificationManager.publish({
        id: this.notificationId,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: { typeCode: 8, title: '联文件 · 数据传输', text: current.text }
        },
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        template: { name: 'downloadTemplate', data: {
          title: '联文件 · 数据传输', fileName: current.text, progressValue: current.percent } }
      })
      // Cancellation can arrive while publish is awaiting the system service.
      if (this.destroyed || this.taskId !== publishingTaskId) { return }
      this.lastPublished = Date.now()
      const becameHealthy = !this.healthy
      this.healthy = true; this.status('')
      if (becameHealthy) {
        console.info('[TransferProtection] ready task=' + this.taskId.toString() +
          ' notification=' + this.notificationId.toString())
        this.changed()
      }
    } catch (error) {
      await this.stop()
      this.attempted = true
      this.status('进度通知不可用，退后台后暂停；回到前台可继续')
      this.changed()
      console.warn('[TransferProtection] publish failed ' + JSON.stringify(error))
    }
  }
  private async stop(): Promise<void> {
    if (this.timer !== 0) { clearTimeout(this.timer); this.timer = 0 }
    const id = this.taskId
    this.taskId = -1; this.notificationId = -1
    const wasHealthy = this.healthy
    this.healthy = false
    if (!this.blocked) { this.status('') }
    else {
      NasConnection.shared().setBackgroundTransferRunning(false)
      AppStorage.setOrCreate('transferProtectionActive', false)
    }
    if (id >= 0 && this.context) {
      try { await backgroundTaskManager.stopBackgroundRunning(this.context, id) }
      catch (error) { console.warn('[TransferProtection] stop failed ' + JSON.stringify(error)) }
      console.info('[TransferProtection] stopped task=' + id.toString())
    }
    if (wasHealthy) { this.changed() }
  }
  destroy(): Promise<void> {
    if (this.destroyed && this.cleanup) { return this.cleanup }
    if (this.destroyed && !this.context) { return Promise.resolve() }
    this.destroyed = true
    this.changed()
    this.listeners = []; this.cancelListeners = []
    this.cleanup = this.queue.catch(() => {}).then(async (): Promise<void> => {
      await this.stop()
      try { backgroundTaskManager.off('continuousTaskCancel', this.cancel) } catch (_) {}
      this.sources.clear(); this.session.clear(); this.context = null
      this.cleanup = null
      AppStorage.setOrCreate('transferProgressText', '')
    })
    return this.cleanup
  }
}

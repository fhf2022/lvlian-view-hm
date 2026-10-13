import { common, wantAgent, WantAgent } from '@kit.AbilityKit'
import { liveViewManager } from '@kit.LiveViewKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { TransferSummary, TransferProgress } from './TransferProgress'
import { TransferLiveViewAssets, TransferLiveViewImages } from './TransferLiveViewAssets'
import { presentTransfer, TransferLiveViewPresentation } from './TransferLiveViewPresentation'

/** Optional display layer. Kit failures never change the data-transfer protection or queues. */
export class TransferLiveViewManager {
  private context: common.UIAbilityContext | null = null
  private foreground: boolean = true
  private dark: boolean = false
  private destroyed: boolean = false
  private attempted: boolean = false
  private blocked: boolean = false
  private active: boolean = false
  private id: number = -1
  private sequence: number = 0
  private lastPublished: number = 0
  private lastKey: string = ''
  private latest: TransferLiveViewPresentation | null = null
  private desired: TransferLiveViewPresentation | null = null
  private queued: boolean = false
  private queue: Promise<void> = Promise.resolve()
  private timer: number = 0
  private agent: WantAgent | null = null
  private images: TransferLiveViewImages | null = null
  private assets: TransferLiveViewAssets = new TransferLiveViewAssets()

  initialize(context: common.UIAbilityContext): void {
    this.context = context; this.foreground = true; this.destroyed = false
    this.blocked = false; this.attempted = false
    this.dark = AppStorage.get<boolean>('isDarkTheme') ?? false
  }
  setForeground(value: boolean): void { this.foreground = value; if (value) { this.schedule() } }
  requestResume(): void {
    if (this.destroyed) { return }
    this.blocked = false; this.attempted = false; this.schedule()
  }
  setDarkTheme(value: boolean): void {
    if (this.dark === value) { return }
    this.dark = value
    if (this.latest?.phase === 'active') {
      const changed = new TransferLiveViewPresentation()
      changed.phase = this.latest.phase; changed.direction = this.latest.direction
      changed.percent = this.latest.percent; changed.knownSize = this.latest.knownSize
      changed.title = this.latest.title; changed.detail = this.latest.detail; changed.keepTime = this.latest.keepTime
      changed.dark = value; changed.key = this.latest.key + ':' + value.toString()
      this.latest = changed; this.desired = changed; this.schedule()
    }
  }
  update(summary: TransferSummary): void {
    if (this.destroyed || summary.count === 0) { return }
    this.latest = presentTransfer(summary, 'active', this.dark)
    this.desired = this.latest; this.schedule()
  }
  finish(summary: TransferSummary, phase: string, tasks: TransferProgress[] = []): void {
    if (this.destroyed) { return }
    this.latest = presentTransfer(summary, phase, this.dark, tasks)
    this.desired = this.latest; this.schedule()
  }
  private schedule(): void {
    if (this.queued || !this.context) { return }
    this.queued = true
    this.queue = this.queue.catch(() => {}).then(async (): Promise<void> => {
      this.queued = false
      await this.reconcile()
    }).catch((error: Object): void => {
      console.warn('[TransferLiveView] reconcile failed ' + JSON.stringify(error))
    })
  }
  private async reconcile(): Promise<void> {
    const value = this.desired
    if (!this.context || !value) { return }
    if (value.phase !== 'active' || this.destroyed) {
      if (this.timer !== 0) { clearTimeout(this.timer); this.timer = 0 }
      await this.end(value)
      this.attempted = false; return
    }
    if (this.blocked || (!this.active && (this.attempted || !this.foreground))) { return }
    if (value.key === this.lastKey && this.active) { return }
    const elapsed = Date.now() - this.lastPublished
    if (this.active && elapsed < 1000) {
      if (this.timer === 0) {
        this.timer = setTimeout((): void => { this.timer = 0; this.schedule() }, 1000 - elapsed)
      }
      return
    }
    let next: TransferLiveViewImages | null = null
    try {
      if (!this.active) {
        this.attempted = true
        if (!await liveViewManager.isLiveViewEnabled() || !this.foreground || this.destroyed ||
          this.desired?.phase !== 'active') { return }
        this.agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: this.context.abilityInfo.bundleName, abilityName: this.context.abilityInfo.name,
            parameters: { transferEntry: true } }],
          actionType: wantAgent.OperationType.START_ABILITY, requestCode: 7109,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        })
        this.id = Date.now() % 2147483647; this.sequence = 0
      }
      next = await this.assets.create(this.context, value)
      if (this.destroyed || (!this.active && (!this.foreground || this.desired?.phase !== 'active'))) { return }
      const live = this.payload(value, next)
      const creating = !this.active
      const result = creating ? await liveViewManager.startLiveView(live) : await liveViewManager.updateLiveView(live)
      if (result.resultCode !== 0) {
        // A non-zero result can mean that only one region failed; the other regions may already exist.
        this.active = true
        await this.end(presentTransfer(new TransferSummary(), 'cancelled', this.dark))
        throw new Error('Live View result ' + result.resultCode.toString())
      }
      this.active = true; this.lastKey = value.key; this.lastPublished = Date.now()
      const previous = this.images; this.images = next; next = null
      if (previous) { await previous.release() }
      AppStorage.setOrCreate('transferLiveViewActive', true)
      if (creating) { console.info('[TransferLiveView] started id=' + this.id.toString()) }
    } catch (error) {
      const code = (error as BusinessError).code
      // Disabling, rights denial or dismissal requires a new explicit session/installation, not a progress-loop retry.
      if (code === 1003500004 || code === 1003500005) { this.blocked = true }
      if (code === 1003500009 || code === 1003500010) {
        this.active = false; this.attempted = true
        AppStorage.setOrCreate('transferLiveViewActive', false)
      }
      this.lastPublished = Date.now()
      console.warn('[TransferLiveView] display failed code=' + String(code ?? 0) +
        ' message=' + String((error as Error).message))
    } finally {
      if (next) { await next.release() }
    }
    // Lifecycle or theme changes arriving during a native call are always reconciled afterwards.
    if (this.desired !== value) { this.schedule() }
  }
  private payload(value: TransferLiveViewPresentation, images: TransferLiveViewImages): liveViewManager.LiveView {
    const primary: liveViewManager.PrimaryData = {
      title: value.title, content: [{ text: value.detail }], keepTime: value.keepTime,
      clickAction: this.agent!,
      layoutData: { layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT },
      extensionData: { type: liveViewManager.ExtensionType.EXTENSION_TYPE_ICON, pic: images.ring }
    }
    const status = value.phase === 'active' ? 1 : -1
    const colour = value.dark ? '#FF000000' : '#FFFFFFFF'
    const capsule: liveViewManager.ProgressCapsule | liveViewManager.TextCapsule = value.knownSize ? {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_PROGRESS, status: status, icon: images.badge,
      tailIcon: images.ring, isContentDisplayed: false, isTailIconDisplayed: true,
      backgroundColor: colour, max: 100, progress: value.percent, indeterminate: true
    } : {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT, status: status, icon: images.badge,
      tailIcon: images.ring, isContentDisplayed: false, isTailIconDisplayed: true,
      backgroundColor: colour, title: '传输'
    }
    return {
      id: this.id, event: 'PROGRESS', subEvent: value.direction === 'download' ? 'DOWNLOAD' : 'UPLOAD',
      sequence: this.sequence++, isMute: true,
      lifeCycleMode: liveViewManager.LifeCycleMode.AUTO_STOP_WHEN_APP_TERMINATE,
      liveViewData: { primary: primary, capsule: capsule }
    }
  }
  private async end(value: TransferLiveViewPresentation): Promise<void> {
    if (!this.active) { return }
    let next: TransferLiveViewImages | null = null
    try {
      if (!this.context) { return }
      next = await this.assets.create(this.context, value)
      const result = await liveViewManager.stopLiveView(this.payload(value, next))
      if (result.resultCode !== 0) { throw new Error('Live View stop result ' + result.resultCode.toString()) }
      this.active = false; this.lastKey = ''
      AppStorage.setOrCreate('transferLiveViewActive', false)
      console.info('[TransferLiveView] ended phase=' + value.phase)
    } catch (error) {
      const code = (error as BusinessError).code
      if (code === 1003500009 || code === 1003500010) { this.active = false }
      else {
        // A bad optional image/region must not keep the capsule alive after cancellation.
        try {
          const result = await liveViewManager.stopLiveView({
            id: this.id, event: 'PROGRESS', sequence: this.sequence++, isMute: true,
            liveViewData: { primary: { title: '传输已结束', content: [{ text: '传输已结束' }], keepTime: 0 },
              capsule: { type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT, status: -1, title: '传输' } }
          })
          if (result.resultCode === 0) { this.active = false }
        } catch (_) {}
      }
      AppStorage.setOrCreate('transferLiveViewActive', this.active)
      console.warn('[TransferLiveView] end failed code=' + String(code ?? 0))
    } finally {
      if (next) { await next.release() }
      if (!this.active && this.images) { await this.images.release(); this.images = null }
    }
  }
  destroy(): Promise<void> {
    this.destroyed = true
    if (this.timer !== 0) { clearTimeout(this.timer); this.timer = 0 }
    this.desired = presentTransfer(new TransferSummary(), 'cancelled', this.dark)
    this.schedule()
    return this.queue.catch(() => {}).then(async (): Promise<void> => {
      await this.end(this.desired!)
      if (this.images) { await this.images.release(); this.images = null }
      await this.assets.release(); this.context = null; this.latest = null; this.desired = null
    })
  }
}

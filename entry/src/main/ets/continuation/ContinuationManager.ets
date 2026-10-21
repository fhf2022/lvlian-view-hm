import { AbilityConstant, common, wantConstant, Want } from '@kit.AbilityKit'
import { commonType, distributedDataObject } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { ContinuationPolicy, ContinuationSnapshot } from './ContinuationModel'
import { ContinuationSnapshotStore } from './ContinuationSnapshotStore'

export class ContinuationAccountRequired extends Error {}

export interface ContinuationPage {
  available: () => boolean
  accountIdentity: () => string
  canReceive: () => boolean
  capture: () => ContinuationSnapshot
  sending: (active: boolean) => void
  pauseSourceVideo: () => Promise<void>
  resumeSourceVideo: () => Promise<void>
  restore: (snapshot: ContinuationSnapshot, valid: () => boolean) => Promise<void>
}

class ContinuationData {
  snapshot: commonType.Asset = { name: '', uri: '', path: '', createTime: '', modifyTime: '', size: '' }
}

/** Owns native transport independently of page/window recreation and transfer queues. */
export class ContinuationManager {
  // 1.0.10 is the first release containing the continuation receiver.
  private static readonly MIN_PEER_VERSION: number = 1000010
  private static instance: ContinuationManager = new ContinuationManager()
  static shared(): ContinuationManager { return ContinuationManager.instance }
  private context: common.UIAbilityContext | null = null
  private page: ContinuationPage | null = null
  private active: boolean | null = null
  private stateUpdating: boolean = false
  private generation: number = 0
  private outgoing: distributedDataObject.DataObject | null = null
  private outgoingPath: string = ''
  private outgoingTimer: number = 0
  private incoming: distributedDataObject.DataObject | null = null
  private observer: distributedDataObject.StatusObserver | null = null
  private incomingId: string = ''
  private incomingSession: string = ''
  private incomingSnapshot: ContinuationSnapshot | null = null
  private receiving: boolean = false
  private restoring: boolean = false
  private exporting: boolean = false
  private waitingIdentity: string = ''
  private handledRequests: string[] = []
  private timeout: number = 0
  private receiveCancel: (() => void) | null = null
  private exportCancel: (() => void) | null = null

  private async bounded<T>(operation: Promise<T>): Promise<T> {
    let timer = 0
    try {
      const deadline = new Promise<T>((_resolve: (value: T) => void, reject: (error: Error) => void): void => {
        this.exportCancel = (): void => { reject(new Error('接续已取消')) }
        timer = setTimeout((): void => {
          this.generation++
          reject(new Error('接续准备超时'))
        }, 30000)
      })
      return await Promise.race([operation, deadline])
    } finally {
      if (timer > 0) { clearTimeout(timer) }
      this.exportCancel = null
    }
  }

  initialize(context: common.UIAbilityContext): void {
    this.context = context
    this.active = null
    this.refresh()
  }

  attach(page: ContinuationPage): void { this.page = page; this.refresh(); this.resumeIncoming() }
  detach(page: ContinuationPage): void {
    if (this.page !== page) { return }
    this.page = null
    this.refresh()
  }

  refresh(): void {
    if (this.context === null || this.stateUpdating) { return }
    const enabled = this.incomingId === '' && !this.receiving && this.page !== null && this.page.available()
    if (this.active === enabled) { this.resumeIncoming(); return }
    this.stateUpdating = true
    const context = this.context
    Promise.resolve().then(() => context.setMissionContinueState(enabled ? AbilityConstant.ContinueState.ACTIVE :
      AbilityConstant.ContinueState.INACTIVE)).then((): void => {
      this.active = enabled
    }).catch((): void => {
      // Unsupported device/system settings must not interfere with normal browsing.
      this.active = enabled
      hilog.warn(0, 'Continuation', 'Unable to update continuation availability')
    }).finally((): void => {
      this.stateUpdating = false
      const current = this.incomingId === '' && !this.receiving && this.page !== null && this.page.available()
      if (current !== enabled) { this.refresh() }
      this.resumeIncoming()
    })
    this.resumeIncoming()
  }

  async export(wantParam: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    const context = this.context
    const page = this.page
    if (context === null || page === null || !page.available() || this.exporting ||
      this.incomingId !== '' || typeof wantParam.targetDevice !== 'string' || wantParam.targetDevice === '') {
      return AbilityConstant.OnContinueResult.REJECT
    }
    if (typeof wantParam.version !== 'number' || wantParam.version < ContinuationManager.MIN_PEER_VERSION) {
      this.message('请先更新另一台设备上的联文件')
      return AbilityConstant.OnContinueResult.MISMATCH
    }
    const token = ++this.generation
    const valid = (): boolean => this.generation === token && this.page === page && this.context === context
    this.exporting = true
    page.sending(true)
    let resumeVideo = false
    try {
      await this.clearOutgoing()
      await ContinuationSnapshotStore.prune(context)
      if (!valid()) { throw new Error('接续已取消') }
      const snapshot = page.capture()
      snapshot.state.requestId = util.generateRandomUUID()
      snapshot.state.createdAt = Date.now()
      snapshot.state.count = snapshot.entries.length
      if (snapshot.state.scene === 'video') {
        resumeVideo = snapshot.state.playing
        await this.bounded(page.pauseSourceVideo())
      }
      this.outgoingPath = context.distributedFilesDir + '/' + ContinuationSnapshotStore.fileName(snapshot.state.requestId)
      const asset = await this.bounded(ContinuationSnapshotStore.write(context, snapshot, valid))
      if (!valid()) { throw new Error('接续已取消') }
      const data = new ContinuationData()
      data.snapshot = asset
      const object = distributedDataObject.create(context, data)
      this.outgoing = object
      const session = distributedDataObject.genSessionId()
      await this.bounded(object.setSessionId(session))
      if (!valid()) { throw new Error('接续已取消') }
      await this.bounded(object.save(wantParam.targetDevice as string))
      if (!valid()) { throw new Error('接续已取消') }
      wantParam.linkfilesContinuationProtocol = 1
      wantParam.linkfilesContinuationRequest = snapshot.state.requestId
      wantParam.linkfilesContinuationSession = session
      wantParam[wantConstant.Params.SUPPORT_CONTINUE_SOURCE_EXIT_KEY] = false
      wantParam[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY] = false
      this.outgoingTimer = setTimeout((): void => { void this.clearOutgoing() }, ContinuationPolicy.MAX_AGE_MS)
      return AbilityConstant.OnContinueResult.AGREE
    } catch (error) {
      this.reportFailure('export', error as Object)
      if (resumeVideo && this.page === page) { page.resumeSourceVideo().catch(() => {}) }
      await this.clearOutgoing()
      this.message('接续准备失败，请稍后重试')
      return AbilityConstant.OnContinueResult.REJECT
    } finally {
      this.exporting = false
      page.sending(false)
      this.refresh()
    }
  }

  receive(want: Want): void {
    const params = want.parameters
    if (params?.linkfilesContinuationProtocol !== 1 ||
      typeof params.linkfilesContinuationRequest !== 'string' ||
      !/^[0-9a-f-]{36}$/.test(params.linkfilesContinuationRequest) ||
      typeof params.linkfilesContinuationSession !== 'string' ||
      !/^[a-zA-Z0-9_-]{1,128}$/.test(params.linkfilesContinuationSession)) {
      this.message('接续版本不兼容，请更新两台设备上的联文件')
      return
    }
    if (this.handledRequests.includes(params.linkfilesContinuationRequest)) { return }
    if (this.page !== null && !this.page.canReceive()) {
      this.message('请结束当前操作后重新接续')
      return
    }
    if (this.incomingId === params.linkfilesContinuationRequest) { return }
    this.cancel()
    this.incomingId = params.linkfilesContinuationRequest
    this.incomingSession = params.linkfilesContinuationSession
    this.handledRequests.push(this.incomingId)
    if (this.handledRequests.length > 32) { this.handledRequests.shift() }
    AppStorage.setOrCreate('continuationPending', true)
    AppStorage.setOrCreate('continuationWaitingForAccount', false)
    this.timeout = setTimeout((): void => {
      this.cancel()
      this.message('接续已超时，请重新发起')
    }, 90000)
    this.refresh()
  }

  resumeIncoming(): void {
    if (this.context === null || this.page === null || this.incomingId === '' ||
      this.receiving || this.restoring || !this.page.canReceive()) { return }
    if (this.waitingIdentity !== '' && this.waitingIdentity === this.page.accountIdentity()) { return }
    if (this.incomingSnapshot !== null) {
      void this.applyIncoming()
    } else {
      void this.loadIncoming()
    }
  }

  private async loadIncoming(): Promise<void> {
    const context = this.context
    if (context === null) { return }
    this.receiving = true
    const token = this.generation
    const id = this.incomingId
    const valid = (): boolean => token === this.generation && this.incomingId === id
    try {
      await ContinuationSnapshotStore.prune(context)
      if (!valid()) { return }
      const object = distributedDataObject.create(context, new ContinuationData())
      this.incoming = object
      await new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
        let finished = false
        const done = (): void => { if (!finished) { finished = true; resolve() } }
        this.receiveCancel = (): void => {
          if (!finished) { finished = true; reject(new Error('接续已取消')) }
        }
        this.observer = (_session: string, _network: string, status: string): void => {
          if (status === 'restored' && valid()) { done() }
        }
        // Subscribe before joining; an already restored asset must not be missed.
        object.on('status', this.observer)
        object.setSessionId(this.incomingSession).catch((): void => {
          if (!finished) { finished = true; reject(new Error('接续会话失败')) }
        })
      })
      this.receiveCancel = null
      if (!valid()) { return }
      const data = object as Object as ContinuationData
      const snapshot = await ContinuationSnapshotStore.read(context, id, data.snapshot, valid)
      if (!valid()) { return }
      this.incomingSnapshot = snapshot
      await this.applyIncoming()
    } catch (error) {
      if (valid()) {
        this.reportFailure('receive', error as Object)
        this.cancel(); this.message('无法恢复接续内容，请重新发起')
      }
    } finally {
      this.receiving = false
      this.refresh()
    }
  }

  private async applyIncoming(): Promise<void> {
    const page = this.page
    const snapshot = this.incomingSnapshot
    if (page === null || snapshot === null || this.restoring || !page.canReceive()) { return }
    this.restoring = true
    const token = this.generation
    const valid = (): boolean => token === this.generation && this.page === page &&
      this.incomingSnapshot === snapshot
    try {
      await page.restore(snapshot, valid)
      if (valid()) { this.cancel() }
    } catch (error) {
      if (valid()) {
        if (error instanceof ContinuationAccountRequired) {
          this.waitingIdentity = page.accountIdentity()
          AppStorage.setOrCreate('continuationWaitingForAccount', true)
        } else {
          this.reportFailure('restore', error as Object)
          this.cancel()
          this.message('接续恢复失败，请检查 NAS 连接后重试')
        }
      }
    } finally {
      this.restoring = false
      this.refresh()
    }
  }

  cancel(): void {
    this.generation++
    this.exportCancel?.()
    if (this.timeout > 0) { clearTimeout(this.timeout); this.timeout = 0 }
    this.receiveCancel?.()
    this.receiveCancel = null
    const object = this.incoming
    if (object !== null) {
      try { if (this.observer !== null) { object.off('status', this.observer) } } catch (_) {}
      void this.releaseObject(object, false)
    }
    if (this.context !== null && this.incomingId !== '') {
      void ContinuationSnapshotStore.remove(this.context.distributedFilesDir + '/' +
        ContinuationSnapshotStore.fileName(this.incomingId))
    }
    this.observer = null; this.incoming = null
    this.incomingId = ''; this.incomingSession = ''; this.incomingSnapshot = null
    this.waitingIdentity = ''
    AppStorage.setOrCreate('continuationPending', false)
    AppStorage.setOrCreate('continuationWaitingForAccount', false)
  }

  private message(value: string): void {
    AppStorage.setOrCreate('continuationMessage', value)
  }

  private reportFailure(stage: string, error: Object): void {
    const code = error !== null && typeof error === 'object' ? (error as BusinessError).code : -1
    // Native code and phase help a later two-device test without logging
    // account IDs, filenames, credentials or transferred payloads.
    hilog.warn(0, 'Continuation', '%{public}s failed, code=%{public}d', stage,
      typeof code === 'number' ? code : -1)
  }

  private async releaseObject(object: distributedDataObject.DataObject, revoke: boolean): Promise<void> {
    if (revoke) { try { await object.revokeSave() } catch (_) {} }
    try { await object.setSessionId() } catch (_) {}
  }

  private async clearOutgoing(): Promise<void> {
    if (this.outgoingTimer > 0) { clearTimeout(this.outgoingTimer); this.outgoingTimer = 0 }
    const object = this.outgoing
    const path = this.outgoingPath
    this.outgoing = null; this.outgoingPath = ''
    if (object !== null) {
      void this.releaseObject(object, true)
    }
    if (path !== '') { await ContinuationSnapshotStore.remove(path) }
  }

  destroy(): void {
    this.cancel()
    void this.clearOutgoing()
    this.handledRequests = []
    this.page = null; this.context = null; this.active = null
  }
}

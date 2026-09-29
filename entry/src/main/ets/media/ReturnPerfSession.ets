import { hilog, hiTraceMeter } from '@kit.PerformanceAnalysisKit'

const LOG_DOMAIN = 0x0D003
const LOG_TAG = 'ReturnPerfSession'

export interface ReleaseEvent {
  ts: number
  path: string
  remainBytes: number
}

/**
 * ReturnPerfSession: 聚焦于 Return Fling vs Normal Fling 差异对比的轻量会话遥测器。
 * 
 * 核心原则：
 * 1. 纯观察者（Observer），不干预任何图片加载、缓存或布局逻辑；
 * 2. 捕获 Viewer 退出尾巴指标（closeDoneTs、liveOriginalBytes、pendingCleanupBytes、release 执行点）；
 * 3. 追踪 First-Fling（首次按下到首划结束）的完整生命周期与归一化成本；
 * 4. 统计 Warm 缩略图重解码率与分时分布（0-500ms, 500-1000ms, 1-3s）；
 * 5. 首划结束后仅输出单条聚合摘要到 Hilog，杜绝高频日志打扰主线程。
 */
export class ReturnPerfSession {
  private static sessionIdCounter: number = 0
  private sessionId: number = 0
  private sessionType: 'normal' | 'return' = 'normal'

  // Viewer 退出尾巴指标
  private closeDoneTs: number = 0
  private viewerOriginalLiveBytes: number = 0
  private pendingCleanupBytes: number = 0
  private pendingCleanupCount: number = 0
  private releaseEvents: ReleaseEvent[] = []

  // First-Fling 窗口生命周期
  private firstFlingArmed: boolean = false
  private firstFlingActive: boolean = false
  private firstFlingCompleted: boolean = false
  private scrollStartTs: number = 0
  private scrollStopTs: number = 0
  private startOffsetY: number = 0
  private stopOffsetY: number = 0
  private scrollDistance: number = 0

  // 首划期间的 LazyItem 与 Image 指标
  private buildLazyCount: number = 0
  private createPixelMapCount: number = 0

  // Warm 集合与重解码集合
  private warmDecodedPaths: Set<string> = new Set()
  private warmRedecodePaths: Set<string> = new Set()

  // 重解码分时分布（基于距 closeDoneTs 的毫秒数）
  private redecodes0to500: number = 0
  private redecodes500to1000: number = 0
  private redecodes1000to3000: number = 0
  private redecodesAfter3000: number = 0

  /**
   * 记录缩略图成功解码完成。
   * 若在首划前，沉淀至 Warm 集合 W；
   * 若在首划中且命中 W，记录至重解码集合 R 并分时统计。
   */
  recordThumbnailComplete(path: string, now: number): void {
    if (!this.firstFlingActive) {
      this.warmDecodedPaths.add(path)
      return
    }

    this.createPixelMapCount += 1
    if (this.warmDecodedPaths.has(path)) {
      this.warmRedecodePaths.add(path)
      const delta = this.closeDoneTs > 0 ? (now - this.closeDoneTs) : (now - this.scrollStartTs)
      if (delta <= 500) {
        this.redecodes0to500 += 1
      } else if (delta <= 1000) {
        this.redecodes500to1000 += 1
      } else if (delta <= 3000) {
        this.redecodes1000to3000 += 1
      } else {
        this.redecodesAfter3000 += 1
      }
    }
  }

  /**
   * 记录首划期间的 Cell 物化。
   */
  recordItemMounted(path: string): void {
    if (this.firstFlingActive) {
      this.buildLazyCount += 1
    }
  }

  /**
   * 武装普通滑动会话（Normal Baseline 对照组）。
   */
  armNormalSession(): void {
    ReturnPerfSession.sessionIdCounter += 1
    this.sessionId = ReturnPerfSession.sessionIdCounter
    this.sessionType = 'normal'
    this.closeDoneTs = 0
    this.viewerOriginalLiveBytes = 0
    this.pendingCleanupBytes = 0
    this.pendingCleanupCount = 0
    this.releaseEvents = []
    this.firstFlingArmed = true
    this.firstFlingActive = false
    this.firstFlingCompleted = false
    this.resetFirstFlingCounters()
  }

  /**
   * 大图退出完成（finishCloseImageViewer），记录 Viewer 退出尾巴并武装首划捕获。
   */
  noteViewerClosed(
    now: number,
    liveBytes: number,
    cleanupBytes: number,
    cleanupCount: number
  ): void {
    ReturnPerfSession.sessionIdCounter += 1
    this.sessionId = ReturnPerfSession.sessionIdCounter
    this.sessionType = 'return'
    this.closeDoneTs = now
    this.viewerOriginalLiveBytes = liveBytes
    this.pendingCleanupBytes = cleanupBytes
    this.pendingCleanupCount = cleanupCount
    this.releaseEvents = []
    this.firstFlingArmed = true
    this.firstFlingActive = false
    this.firstFlingCompleted = false
    this.resetFirstFlingCounters()

    try {
      hiTraceMeter.startTrace('ReturnPerf:CloseDone', this.sessionId)
      hiTraceMeter.finishTrace('ReturnPerf:CloseDone', this.sessionId)
    } catch (_) {}
  }

  /**
   * 记录 release() 释放切片实际执行点。
   */
  recordViewerRelease(path: string, remainBytes: number, now: number): void {
    this.releaseEvents.push({
      ts: now,
      path: path,
      remainBytes: remainBytes
    })
  }

  private resetFirstFlingCounters(): void {
    this.scrollStartTs = 0
    this.scrollStopTs = 0
    this.startOffsetY = 0
    this.stopOffsetY = 0
    this.scrollDistance = 0
    this.buildLazyCount = 0
    this.createPixelMapCount = 0
    this.warmRedecodePaths.clear()
    this.redecodes0to500 = 0
    this.redecodes500to1000 = 0
    this.redecodes1000to3000 = 0
    this.redecodesAfter3000 = 0
  }

  /**
   * 滚动开始：触发 First-Fling 捕获窗口。
   */
  noteScrollStart(offsetY: number, now: number): void {
    if (!this.firstFlingArmed) {
      ReturnPerfSession.sessionIdCounter += 1
      this.sessionId = ReturnPerfSession.sessionIdCounter
      this.sessionType = 'normal'
      this.closeDoneTs = 0
      this.viewerOriginalLiveBytes = 0
      this.pendingCleanupBytes = 0
      this.pendingCleanupCount = 0
      this.releaseEvents = []
      this.firstFlingArmed = true
      this.firstFlingCompleted = false
      this.resetFirstFlingCounters()
    }
    this.firstFlingArmed = false
    this.firstFlingActive = true
    this.scrollStartTs = now
    this.startOffsetY = offsetY

    try {
      hiTraceMeter.startTrace(`FirstFling:${this.sessionType}`, this.sessionId)
    } catch (_) {}
  }

  /**
   * 滚动停止：结束 First-Fling，输出唯一的单条聚合摘要。
   */
  noteScrollStop(offsetY: number, now: number): void {
    if (!this.firstFlingActive) {
      return
    }
    this.firstFlingActive = false
    this.firstFlingCompleted = true
    this.scrollStopTs = now
    this.stopOffsetY = offsetY
    this.scrollDistance = Math.abs(this.stopOffsetY - this.startOffsetY)

    try {
      hiTraceMeter.finishTrace(`FirstFling:${this.sessionType}`, this.sessionId)
    } catch (_) {}

    this.dumpSingleSummary()
  }

  private dumpSingleSummary(): void {
    const durMs = Math.max(1, this.scrollStopTs - this.scrollStartTs)
    const distPx = Math.round(this.scrollDistance)
    const normFactor = distPx > 100 ? (10000.0 / distPx) : 1.0

    const wSize = this.warmDecodedPaths.size
    const rSize = this.warmRedecodePaths.size
    const redecodeRate = wSize > 0 ? ((rSize / wSize) * 100).toFixed(1) + '%' : '0.0%'

    const pmPerBuild = this.buildLazyCount > 0 ? (this.createPixelMapCount / this.buildLazyCount).toFixed(2) : '0.00'
    const normBuild = (this.buildLazyCount * normFactor).toFixed(1)
    const normPm = (this.createPixelMapCount * normFactor).toFixed(1)

    const deltaClose = this.closeDoneTs > 0 ? `+${this.scrollStartTs - this.closeDoneTs}ms` : 'n/a'
    const liveMB = (this.viewerOriginalLiveBytes / (1024 * 1024)).toFixed(1)
    const pendMB = (this.pendingCleanupBytes / (1024 * 1024)).toFixed(1)

    const summary = `[ReturnPerfSession] type=${this.sessionType} id=${this.sessionId} ` +
      `dur=${durMs}ms dist=${distPx}px Δclose=${deltaClose} ` +
      `BuildLazy=${this.buildLazyCount} (norm=${normBuild}/10k) ` +
      `CreatePM=${this.createPixelMapCount} (norm=${normPm}/10k, pm/build=${pmPerBuild}) ` +
      `WarmRedecode=${rSize}/${wSize}(${redecodeRate}) buckets[0-500ms:${this.redecodes0to500}, 500-1s:${this.redecodes500to1000}, 1-3s:${this.redecodes1000to3000}] ` +
      `Tail[live=${liveMB}MB, pendBytes=${pendMB}MB, pendCount=${this.pendingCleanupCount}, releases=${this.releaseEvents.length}]`

    hilog.info(LOG_DOMAIN, LOG_TAG, summary)
  }

  resetAll(): void {
    this.warmDecodedPaths.clear()
    this.warmRedecodePaths.clear()
    this.firstFlingArmed = false
    this.firstFlingActive = false
    this.firstFlingCompleted = false
    this.resetFirstFlingCounters()
  }
}

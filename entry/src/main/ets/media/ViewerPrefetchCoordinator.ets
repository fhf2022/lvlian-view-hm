import { hilog } from '@kit.PerformanceAnalysisKit'
import { FileEntry } from '../model/FileEntry'

const PREFETCH_DOMAIN: number = 0xD003
const PREFETCH_TAG: string = 'ViewerPrefetch'

/**
 * 状态定义：严格的三层状态模型
 */
export enum ViewerEntryState {
  NONE = 'none',
  PREVIEW_READY = 'preview_ready',
  ORIGINAL_FILE_READY = 'original_file_ready',
  ORIGINAL_PIXELMAP_READY = 'original_pixelmap_ready'
}

export interface ViewerPrefetchDelegate {
  isViewerActive: () => boolean
  isInteractionBusy: () => boolean
  shouldAutoPrefetch: () => boolean
  isFileCached: (entry: FileEntry) => boolean
  downloadOriginalFile: (entry: FileEntry, shouldContinue: () => boolean) => Promise<string>
  onOriginalFileReady: (entry: FileEntry, localPath: string) => Promise<void>
}

interface PrefetchTarget {
  entry: FileEntry
  tier: number
}

/**
 * ViewerPrefetchCoordinator:
 * 滑动窗口式分层预加载协调器
 *
 * 核心设计规则：
 * 1. Decoded PixelMap 预算：只允许当前 n = 1 张（严格保持 A3 基线，绝不预解码邻图 PixelMap）；
 * 2. Original disk cache 预算：允许 n-2 ~ n+2，最多 5 张压缩原图文件落盘；
 * 3. 预加载原图 ≠ 预解码原图：邻图仅在静默期将原图压缩文件下载并写入磁盘缓存（CacheManager）；
 * 4. 两级优先级门控：
 *    - Tier 1（n±1）：当前 Original ready 且通过 200ms 空闲门控后开始；
 *    - Tier 2（n±2）：低优先级机会式预取，仅在 Tier 1 全部就绪且 Viewer 仍处于空闲时串行推进；
 * 5. 严格串行削峰：concurrency = 1，同一时刻最多下载 1 个原图文件，HTTP 流式直落磁盘不驻留 ArrayBuffer；
 * 6. 方向优先：根据 viewerLastNavigationDirection，若向右优先 n+1/n+2，若向左优先 n-1/n-2；
 * 7. Generation 立即打断：切图手势或换页时自增 generation，立即中断在途低优先级预取并滚动窗口。
 */
export class ViewerPrefetchCoordinator {
  private currentIndex: number = -1
  private direction: number = 1
  private generation: number = 0
  private idleTimerId: number = -1
  private isPrefetching: boolean = false
  private activePrefetchPath: string = ''
  private entryStates: Map<string, ViewerEntryState> = new Map<string, ViewerEntryState>()
  private images: FileEntry[] = []
  private delegate: ViewerPrefetchDelegate

  constructor(delegate: ViewerPrefetchDelegate) {
    this.delegate = delegate
  }

  getEntryState(path: string): ViewerEntryState {
    const s = this.entryStates.get(path)
    return s !== undefined ? s : ViewerEntryState.NONE
  }

  setEntryState(path: string, state: ViewerEntryState): void {
    this.entryStates.set(path, state)
  }

  onViewerOpened(initialIndex: number, images: FileEntry[]): void {
    this.disarmIdleGate()
    this.generation++
    this.currentIndex = initialIndex
    this.direction = 1
    this.images = images
    this.isPrefetching = false
    this.activePrefetchPath = ''
    this.entryStates.clear()
    hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG, `[Coordinator] opened at index=${initialIndex} count=${images.length}`)
  }

  onViewerIndexChanged(newIndex: number, images: FileEntry[]): void {
    this.disarmIdleGate()
    this.generation++
    if (this.currentIndex >= 0 && newIndex !== this.currentIndex) {
      this.direction = newIndex > this.currentIndex ? 1 : -1
    }
    const previousIndex = this.currentIndex
    this.currentIndex = newIndex
    this.images = images

    // 当前项之外的原图 PixelMap 降级为 ORIGINAL_FILE_READY（因为 trimViewerOriginalState 会回收其 PixelMap）
    if (previousIndex >= 0 && previousIndex < images.length && previousIndex !== newIndex) {
      const prevPath = images[previousIndex].path
      if (this.getEntryState(prevPath) === ViewerEntryState.ORIGINAL_PIXELMAP_READY) {
        this.setEntryState(prevPath, ViewerEntryState.ORIGINAL_FILE_READY)
      }
    }

    // 内存防泄漏：修剪窗口半径外的条目状态记录（覆盖 ±2 窗口加上 2 槽裕量）
    const minKeep = newIndex - 4
    const maxKeep = newIndex + 4
    const keepPaths: Record<string, boolean> = {}
    for (let i = Math.max(0, minKeep); i <= Math.min(images.length - 1, maxKeep); i++) {
      keepPaths[images[i].path] = true
    }
    const removeKeys: string[] = []
    this.entryStates.forEach((_, key: string) => {
      if (!keepPaths[key]) {
        removeKeys.push(key)
      }
    })
    for (const key of removeKeys) {
      this.entryStates.delete(key)
    }

    hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG,
      `[Coordinator] indexChanged: from=${previousIndex} to=${newIndex} dir=${this.direction} gen=${this.generation}`)
  }

  onCurrentOriginalRevealed(path: string): void {
    this.setEntryState(path, ViewerEntryState.ORIGINAL_PIXELMAP_READY)
    hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG, `[Coordinator] current original revealed: ${path}, arming idle gate`)
    this.armIdleGate(200)
  }

  onUserInteraction(): void {
    this.disarmIdleGate()
  }

  onInteractionEnded(): void {
    // 交互结束时，若当前原图已呈现且处于空闲，重新装载空闲门控
    if (this.currentIndex >= 0 && this.currentIndex < this.images.length) {
      const currentPath = this.images[this.currentIndex].path
      if (this.getEntryState(currentPath) === ViewerEntryState.ORIGINAL_PIXELMAP_READY) {
        this.armIdleGate(200)
      }
    }
  }

  armIdleGate(delayMs: number = 200): void {
    this.disarmIdleGate()
    if (!this.delegate.isViewerActive() ||
      this.delegate.isInteractionBusy() ||
      !this.delegate.shouldAutoPrefetch()) {
      return
    }

    const gen = this.generation
    this.idleTimerId = setTimeout(() => {
      this.idleTimerId = -1
      if (gen !== this.generation) {
        return
      }
      this.runPrefetch(gen)
    }, delayMs)
  }

  disarmIdleGate(): void {
    if (this.idleTimerId !== -1) {
      clearTimeout(this.idleTimerId)
      this.idleTimerId = -1
    }
  }

  onViewerClosed(): void {
    this.disarmIdleGate()
    this.generation++
    this.currentIndex = -1
    this.isPrefetching = false
    this.activePrefetchPath = ''
    this.entryStates.clear()
    hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG, '[Coordinator] closed, all prefetch cancelled')
  }

  private async runPrefetch(gen: number): Promise<void> {
    if (gen !== this.generation ||
      !this.delegate.isViewerActive() ||
      this.delegate.isInteractionBusy() ||
      !this.delegate.shouldAutoPrefetch() ||
      this.isPrefetching) {
      return
    }

    const targetObj = this.findNextTarget()
    if (targetObj === null) {
      return
    }

    const target = targetObj.entry
    const tier = targetObj.tier
    this.isPrefetching = true
    this.activePrefetchPath = target.path
    const targetName = target.name
    const targetPath = target.path
    hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG,
      `[Coordinator] start serialized original file prefetch (tier=${tier}): ${targetName} (gen=${gen})`)

    const shouldContinue = (): boolean => {
      return gen === this.generation &&
        this.delegate.isViewerActive() &&
        !this.delegate.isInteractionBusy() &&
        this.delegate.shouldAutoPrefetch()
    }

    try {
      const localPath = await this.delegate.downloadOriginalFile(target, shouldContinue)
      if (gen === this.generation && this.delegate.isViewerActive()) {
        this.setEntryState(targetPath, ViewerEntryState.ORIGINAL_FILE_READY)
        await this.delegate.onOriginalFileReady(target, localPath)
        hilog.info(PREFETCH_DOMAIN, PREFETCH_TAG,
          `[Coordinator] original file cached & ready (tier=${tier}, no PixelMap): ${targetName}`)
      }
    } catch (err) {
      hilog.warn(PREFETCH_DOMAIN, PREFETCH_TAG,
        `[Coordinator] prefetch error for ${targetName}: ${JSON.stringify(err)}`)
    } finally {
      this.isPrefetching = false
      this.activePrefetchPath = ''
      // 若当前 generation 仍有效且空闲，继续串行预取窗口内下一个目标（覆盖 ±2 窗口）
      if (gen === this.generation &&
        this.delegate.isViewerActive() &&
        !this.delegate.isInteractionBusy() &&
        this.delegate.shouldAutoPrefetch()) {
        this.runPrefetch(gen)
      }
    }
  }

  private findNextTarget(): PrefetchTarget | null {
    if (this.currentIndex < 0 || this.currentIndex >= this.images.length) {
      return null
    }

    // Tier 1: n ± 1（高优先级即时邻图，按当前滑动方向优先）
    const tier1: number[] = this.direction >= 0
      ? [this.currentIndex + 1, this.currentIndex - 1]
      : [this.currentIndex - 1, this.currentIndex + 1]

    for (const candIdx of tier1) {
      if (candIdx < 0 || candIdx >= this.images.length) {
        continue
      }
      const entry = this.images[candIdx]
      if (entry.path === this.images[this.currentIndex].path) {
        continue
      }

      const state = this.getEntryState(entry.path)
      if (state === ViewerEntryState.ORIGINAL_PIXELMAP_READY ||
        state === ViewerEntryState.ORIGINAL_FILE_READY) {
        continue
      }

      // 如果本地磁盘缓存已经存在（例如之前下载过或已在缓存中）
      if (this.delegate.isFileCached(entry)) {
        this.setEntryState(entry.path, ViewerEntryState.ORIGINAL_FILE_READY)
        this.delegate.onOriginalFileReady(entry, '').catch((): void => {})
        continue
      }

      return { entry: entry, tier: 1 }
    }

    // Tier 2: n ± 2（低优先级机会式预取，仅在 Tier 1 全部就绪后启动）
    const tier2: number[] = this.direction >= 0
      ? [this.currentIndex + 2, this.currentIndex - 2]
      : [this.currentIndex - 2, this.currentIndex + 2]

    for (const candIdx of tier2) {
      if (candIdx < 0 || candIdx >= this.images.length) {
        continue
      }
      const entry = this.images[candIdx]
      if (entry.path === this.images[this.currentIndex].path) {
        continue
      }

      const state = this.getEntryState(entry.path)
      if (state === ViewerEntryState.ORIGINAL_PIXELMAP_READY ||
        state === ViewerEntryState.ORIGINAL_FILE_READY) {
        continue
      }

      // 如果本地磁盘缓存已经存在（例如之前下载过或已在缓存中）
      if (this.delegate.isFileCached(entry)) {
        this.setEntryState(entry.path, ViewerEntryState.ORIGINAL_FILE_READY)
        this.delegate.onOriginalFileReady(entry, '').catch((): void => {})
        continue
      }

      return { entry: entry, tier: 2 }
    }

    return null
  }
}

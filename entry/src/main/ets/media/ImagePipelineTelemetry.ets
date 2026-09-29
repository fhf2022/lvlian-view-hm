/**
 * ImagePipelineTelemetry: 纯只读的图片管线 Telemetry 遥测器。
 *
 * 核心设计原则：
 * 1. 纯观察者（Observer），绝不拦截、延迟或阻止任何图片加载行为；
 * 2. 统计单帧 Image pipeline 启动峰值（Peak starts / frame）；
 * 3. 统计并发 in-flight 峰值与当前在途数；
 * 4. 统计过期/已失效异步回调（stale completion）拦截次数；
 * 5. 统计可见区条目就绪率（visible-enter ready rate）；
 * 6. 在 fling 滚动停止时输出聚合指标，提供无侵入式的客观负载量化。
 */
export class ImagePipelineTelemetry {
  // 单帧洪峰统计（以 16ms 作为一个帧窗口桶）
  private currentFrameStart: number = 0
  private startsInCurrentFrame: number = 0
  private peakStartsPerFrame: number = 0
  private totalStarts: number = 0

  // 并发 in-flight 统计
  private inFlight: number = 0
  private peakInFlight: number = 0

  // 结果与失效统计
  private totalCompleted: number = 0
  private totalErrors: number = 0
  private staleCompletions: number = 0

  // 可见区就绪率统计
  private visibleEnterTotal: number = 0
  private visibleEnterReady: number = 0

  /**
   * 记录一次 Image 管线启动（如 GridItem 真实挂载 / 开始解析 source）。
   */
  recordPipelineStart(path: string, surface: string = 'grid'): void {
    const now = Date.now()
    if (now - this.currentFrameStart < 16) {
      this.startsInCurrentFrame += 1
    } else {
      this.currentFrameStart = now
      this.startsInCurrentFrame = 1
    }
    if (this.startsInCurrentFrame > this.peakStartsPerFrame) {
      this.peakStartsPerFrame = this.startsInCurrentFrame
    }
    this.totalStarts += 1
    this.inFlight += 1
    if (this.inFlight > this.peakInFlight) {
      this.peakInFlight = this.inFlight
    }
  }

  /**
   * 记录一次 Image 管线成功渲染完成（onComplete）。
   */
  recordPipelineComplete(path: string, surface: string = 'grid'): void {
    if (this.inFlight > 0) {
      this.inFlight -= 1
    }
    this.totalCompleted += 1
  }

  /**
   * 记录一次 Image 管线加载失败（onError）。
   */
  recordPipelineError(path: string, surface: string = 'grid'): void {
    if (this.inFlight > 0) {
      this.inFlight -= 1
    }
    this.totalErrors += 1
  }

  /**
   * 记录一次被拦截的过期异步回调（stale completion）。
   */
  recordStaleCompletion(path: string, reason: string = ''): void {
    this.staleCompletions += 1
  }

  /**
   * 记录条目进入可视区时的就绪状态（用于统计就绪率）。
   */
  recordVisibleEnter(path: string, isReady: boolean): void {
    this.visibleEnterTotal += 1
    if (isReady) {
      this.visibleEnterReady += 1
    }
  }

  /**
   * 生成当前 Telemetry 状态的聚合诊断字符串。
   */
  dumpStats(): string {
    const rate = this.visibleEnterTotal > 0
      ? ((this.visibleEnterReady / this.visibleEnterTotal) * 100).toFixed(1) + '%'
      : '100.0%'
    return `[ImageTelemetry] readyRate=${rate} (${this.visibleEnterReady}/${this.visibleEnterTotal}) ` +
      `peakStarts=${this.peakStartsPerFrame}/frame inFlight(peak=${this.peakInFlight},curr=${this.inFlight}) ` +
      `completed=${this.totalCompleted} staleIgnored=${this.staleCompletions}`
  }

  /**
   * 获取当前各指标快照。
   */
  getPeakStartsPerFrame(): number {
    return this.peakStartsPerFrame
  }

  getPeakInFlight(): number {
    return this.peakInFlight
  }

  getCurrentInFlight(): number {
    return this.inFlight
  }

  getStaleCompletions(): number {
    return this.staleCompletions
  }

  /**
   * 重置遥测数据（例如目录切换或刷新）。
   */
  reset(): void {
    this.currentFrameStart = 0
    this.startsInCurrentFrame = 0
    this.peakStartsPerFrame = 0
    this.totalStarts = 0
    this.inFlight = 0
    this.peakInFlight = 0
    this.totalCompleted = 0
    this.totalErrors = 0
    this.staleCompletions = 0
    this.visibleEnterTotal = 0
    this.visibleEnterReady = 0
  }
}

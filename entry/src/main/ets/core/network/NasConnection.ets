import { UgreenError, UgreenErrorKind } from '../../ugreen/UgreenErrors'

export type NasConnectionState = 'unknown' | 'online' | 'unavailable' | 'connecting'
export type NasConnectionListener = (state: NasConnectionState) => void

/** One circuit and one recovery request per NAS, never one timer per thumbnail. */
export class NasConnection {
  private static instance: NasConnection | null = null
  private baseUrl: string = ''
  private state: NasConnectionState = 'unknown'
  private listeners: NasConnectionListener[] = []
  private probe: (() => Promise<boolean>) | null = null
  private pending: Promise<boolean> | null = null
  private timer: number = 0
  private foreground: boolean = true
  private backgroundTransferActive: boolean = false
  private phoneOffline: boolean = false
  private retryIndex: number = 0
  private generation: number = 0
  private serial: number = 0
  private lastSuccess: number = 0
  private lastFailure: number = 0
  private firstAttempt: number = 0

  static shared(): NasConnection {
    if (NasConnection.instance === null) { NasConnection.instance = new NasConnection() }
    return NasConnection.instance
  }

  current(): NasConnectionState { return this.state }
  canRequest(): boolean { return !this.phoneOffline && this.state !== 'unavailable' && this.state !== 'connecting' }
  onChange(listener: NasConnectionListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener) }
  }
  offChange(listener: NasConnectionListener): void {
    this.listeners = this.listeners.filter((item: NasConnectionListener): boolean => item !== listener)
  }

  configure(baseUrl: string, probe: () => Promise<boolean>): void {
    const next = baseUrl.replace(/\/$/, '')
    this.probe = probe
    if (next === this.baseUrl) { return }
    this.cancelTimer()
    this.generation += 1
    this.pending = null
    this.baseUrl = next
    this.retryIndex = 0
    this.lastSuccess = ++this.serial
    this.lastFailure = this.serial
    this.firstAttempt = this.serial
    this.update(this.phoneOffline ? 'unavailable' : 'unknown')
    this.schedule()
  }

  clear(): void {
    this.cancelTimer()
    this.generation += 1
    this.baseUrl = ''
    this.probe = null
    this.pending = null
    this.firstAttempt = ++this.serial
    this.update('unknown')
  }

  markUnavailable(): void {
    if (this.baseUrl.length === 0) { return }
    this.lastFailure = ++this.serial
    this.update('unavailable')
    this.schedule()
  }

  setForeground(value: boolean): void {
    const resumed = value && !this.foreground
    this.foreground = value
    if (!value && !this.backgroundTransferActive) { this.cancelTimer() }
    else if (resumed && this.state === 'unavailable') { this.retryNow().catch(() => {}) }
  }

  setBackgroundTransferRunning(value: boolean): void {
    this.backgroundTransferActive = value
    if (!value && !this.foreground) { this.cancelTimer() }
  }

  setPhoneOffline(value: boolean): void {
    const restored = this.phoneOffline && !value
    this.phoneOffline = value
    if (value && this.baseUrl.length > 0) {
      this.cancelTimer()
      this.lastFailure = ++this.serial
      this.update('unavailable')
    } else if (restored && (this.foreground || this.backgroundTransferActive) && this.state === 'unavailable') {
      this.retryNow().catch(() => {})
    }
  }

  begin(url: string, recovery: boolean = false): number {
    if (!this.matches(url)) { return 0 }
    if (this.phoneOffline || (!recovery && !this.canRequest())) {
      throw new UgreenError(UgreenErrorKind.NAS_UNAVAILABLE,
        this.phoneOffline ? '手机暂无网络，已缓存内容仍可浏览' : 'NAS 暂时无法连接，已缓存内容仍可浏览')
    }
    return ++this.serial
  }

  response(url: string, serial: number, status: number): void {
    if (!this.matches(url) || serial <= this.firstAttempt) { return }
    if (status === 502 || status === 503 || status === 504) {
      this.failed(url, serial)
      throw new UgreenError(UgreenErrorKind.NAS_UNAVAILABLE, 'NAS 暂时无法连接，请稍后重试', status)
    }
    if (serial < this.lastFailure) { return }
    this.lastSuccess = Math.max(this.lastSuccess, serial)
    if (this.phoneOffline) { return }
    this.retryIndex = 0
    this.cancelTimer()
    this.update('online')
  }

  failed(url: string, serial: number): void {
    if (!this.matches(url) || serial === 0 || serial < this.lastSuccess) { return }
    this.lastFailure = Math.max(this.lastFailure, serial)
    this.update('unavailable')
    this.schedule()
  }

  async retryNow(): Promise<boolean> {
    if (this.pending !== null) { return await this.pending }
    if (this.probe === null || this.phoneOffline || (!this.foreground && !this.backgroundTransferActive)) { return false }
    this.cancelTimer()
    const generation = this.generation
    const probe = this.probe
    this.update('connecting')
    const pending = this.runProbe(probe, generation)
    this.pending = pending
    try { return await pending }
    finally {
      if (this.pending === pending) { this.pending = null }
      if (generation === this.generation) { this.schedule() }
    }
  }

  private async runProbe(probe: () => Promise<boolean>, generation: number): Promise<boolean> {
    const startedAt = this.serial
    let reachable = false
    try { reachable = await probe() } catch (_) {}
    if (generation !== this.generation) { return false }
    if (!reachable && this.lastSuccess > startedAt && !this.phoneOffline) { return true }
    if (reachable && !this.phoneOffline) {
      this.lastSuccess = ++this.serial
      this.retryIndex = 0
      this.update('online')
      return true
    }
    this.update('unavailable')
    this.retryIndex = Math.min(4, this.retryIndex + 1)
    return false
  }

  private matches(url: string): boolean {
    return this.baseUrl.length > 0 && (url === this.baseUrl || url.startsWith(this.baseUrl + '/'))
  }
  private schedule(): void {
    if (this.timer !== 0 || this.pending !== null || (!this.foreground && !this.backgroundTransferActive) || this.phoneOffline ||
      this.state !== 'unavailable' || this.probe === null) { return }
    const delays: number[] = [5000, 10000, 20000, 40000, 60000]
    this.timer = setTimeout((): void => {
      this.timer = 0
      this.retryNow().catch(() => {})
    }, delays[this.retryIndex])
  }
  private cancelTimer(): void {
    if (this.timer !== 0) { clearTimeout(this.timer); this.timer = 0 }
  }
  private update(next: NasConnectionState): void {
    if (this.state === next) { return }
    this.state = next
    console.info('[NasConnection] state=' + next)
    for (const listener of this.listeners.slice()) {
      try { listener(next) } catch (_) {}
    }
  }
}

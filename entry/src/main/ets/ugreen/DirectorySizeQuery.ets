import { JsonObject } from '../core/network/HttpTypes'

/** One property dialog owns one NAS calculation. No directory listing or persistent cache. */
export class DirectorySizeQuery {
  private timer: number = 0
  private started: boolean = false
  private stopped: boolean = false
  private complete: boolean = false
  private calculateId: string | number = ''
  private cancelledId: string | number = ''
  private listener: ((size: number | null) => void) | null = null
  private read: () => Promise<JsonObject>
  private cancel: (id: string | number) => Promise<void>
  private valid: () => boolean

  constructor(read: () => Promise<JsonObject>, cancel: (id: string | number) => Promise<void>,
    valid: () => boolean) {
    this.read = read
    this.cancel = cancel
    this.valid = valid
  }

  start(listener: (size: number | null) => void): void {
    if (this.started || this.stopped) { return }
    this.started = true
    this.listener = listener
    this.poll()
  }

  stop(): void {
    this.stopped = true
    this.listener = null
    if (this.timer > 0) { clearTimeout(this.timer); this.timer = 0 }
    this.cancelCalculation()
  }

  private cancelCalculation(): void {
    if (this.complete || this.calculateId === '' || this.calculateId === this.cancelledId) { return }
    const id = this.calculateId
    this.cancelledId = id
    this.cancel(id).catch((): void => { /* Best effort; never reopen a dismissed dialog. */ })
  }

  private async poll(): Promise<void> {
    try {
      if (!this.valid()) { throw new Error('Session changed') }
      const data = await this.read()
      const id = data['calculate_id']
      if (typeof id === 'string' || typeof id === 'number') { this.calculateId = id }
      const status = data['status']
      this.complete = status === 1 || status === 2
      // Closing may race the initial request, before the server returns its ID.
      if (this.stopped) { this.cancelCalculation(); return }
      if (!this.valid()) { throw new Error('Session changed') }
      if (status === 1) {
        const size = data['size']
        if (typeof size !== 'number' || !Number.isFinite(size) || size < 0) {
          throw new Error('Invalid directory size')
        }
        if (this.listener !== null) { this.listener(size) }
        this.stop()
      } else if (status === 0) {
        // Match the web property dialog: one sequential request, one timer.
        this.timer = setTimeout((): void => { this.timer = 0; this.poll() }, 700)
      } else {
        throw new Error('Directory size unavailable')
      }
    } catch (_) {
      if (!this.stopped && this.listener !== null) { this.listener(null) }
      this.stop()
    }
  }
}

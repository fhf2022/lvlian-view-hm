export type PreviewTaskRunner = () => Promise<void>

interface PreviewTask {
  key: string
  priority: number
  sequence: number
  runner: PreviewTaskRunner
  retries: number
  notBefore: number
  recover: ((error: Object) => boolean) | null
  valid: (() => boolean) | null
  retryDelay: (() => number) | null
}

/**
 * Small priority queue for visible thumbnails. It bounds work even when a
 * lazy container reports a burst of appearing items during a fast scroll.
 */
export class PreviewLoadQueue {
  private pending: PreviewTask[] = []
  private activeKeys: Set<string> = new Set<string>()
  private activeCount: number = 0
  private sequence: number = 0
  private wakeTimer: number = 0
  private readyWhileActive: Set<string> = new Set()
  private maxConcurrent: number
  private maxPending: number

  constructor(maxConcurrent: number = 2, maxPending: number = 32) {
    this.maxConcurrent = Math.max(1, maxConcurrent)
    this.maxPending = Math.max(1, maxPending)
  }

  enqueue(key: string, priority: number, runner: PreviewTaskRunner,
    recover: ((error: Object) => boolean) | null = null, valid: (() => boolean) | null = null,
    retryDelay: (() => number) | null = null): boolean {
    if (key.length === 0 || this.activeKeys.has(key)) {
      return false
    }
    if (this.promote(key, priority)) {
      return false
    }
    if (this.pending.length >= this.maxPending) {
      // Never evict an accepted task silently. The caller owns the per-file
      // loading flag and can retry a rejected task, while a silently evicted
      // task would remain stuck in "loading" forever.
      return false
    }
    this.pending.push({
      key: key,
      priority: priority,
      sequence: this.sequence++,
      runner: runner,
      retries: 0,
      notBefore: 0,
      recover: recover,
      valid: valid,
      retryDelay: retryDelay
    })
    this.pump()
    return true
  }

  /** Promote a queued preload without replacing its runner or owner token. */
  promote(key: string, priority: number): boolean {
    const task = this.pending.find((item: PreviewTask): boolean => item.key === key)
    if (task === undefined) {
      return false
    }
    task.priority = Math.min(task.priority, priority)
    return true
  }

  cancelPending(): string[] {
    this.readyWhileActive.clear()
    const keys = this.pending.map((task: PreviewTask): string => task.key)
    this.pending = []
    if (this.wakeTimer > 0) { clearTimeout(this.wakeTimer); this.wakeTimer = 0 }
    return keys
  }

  clear(): void {
    this.cancelPending()
  }

  activeCountValue(): number {
    return this.activeCount
  }

  pendingCount(): number {
    return this.pending.length
  }

  /** A server readiness event advances an existing task; never admits new work. */
  retryNow(key: string): void {
    const task = this.pending.find((item: PreviewTask): boolean => item.key === key)
    if (task !== undefined) { task.notBefore = 0; this.pump() }
    else if (this.activeKeys.has(key)) { this.readyWhileActive.add(key) }
  }

  private pump(): void {
    if (this.wakeTimer > 0) { clearTimeout(this.wakeTimer); this.wakeTimer = 0 }
    while (this.activeCount < this.maxConcurrent && this.pending.length > 0) {
      this.pending.sort((left: PreviewTask, right: PreviewTask): number => {
        if (left.priority !== right.priority) {
          return left.priority - right.priority
        }
        return left.sequence - right.sequence
      })
      const ready = this.pending.findIndex((task: PreviewTask): boolean => task.notBefore <= Date.now())
      if (ready < 0) {
        const due = this.pending.reduce((time: number, task: PreviewTask): number => Math.min(time, task.notBefore), Infinity)
        this.wakeTimer = setTimeout((): void => { this.wakeTimer = 0; this.pump() }, Math.max(1, due - Date.now()))
        return
      }
      const task = this.pending.splice(ready, 1)[0]
      if (task === undefined) {
        return
      }
      this.activeCount += 1
      this.activeKeys.add(task.key)
      let retry = false
      task.runner().catch((error: Object): void => {
        // A thumbnail awaiting the server yields its worker to other files.
        // All deferred tasks share one timer and the original pending limit.
        if (task.recover !== null && task.recover(error) && task.retries < 5 &&
          (task.valid === null || task.valid()) && this.pending.length < this.maxPending) {
          const delay = task.retryDelay === null ? 0 : task.retryDelay()
          task.notBefore = Date.now() + (delay > 0 ? delay : 1000 * Math.pow(2, task.retries))
          task.retries++
          retry = true
        }
      }).finally((): void => {
        this.activeCount = Math.max(0, this.activeCount - 1)
        this.activeKeys.delete(task.key)
        const ready = this.readyWhileActive.delete(task.key)
        if (retry && (task.valid === null || task.valid()) && this.pending.length < this.maxPending) {
          if (ready) { task.notBefore = 0 }
          this.pending.push(task)
        }
        this.pump()
      })
    }
  }
}

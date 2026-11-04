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
  wanted: boolean
}

/**
 * Small priority queue for visible thumbnails. It bounds work even when a
 * lazy container reports a burst of appearing items during a fast scroll.
 */
export class PreviewLoadQueue {
  private pending: PreviewTask[] = []
  private activeTasks: Map<string, PreviewTask> = new Map()
  private activeCount: number = 0
  private sequence: number = 0
  private wakeTimer: number = 0
  private paused: boolean = false
  private readyWhileActive: Set<string> = new Set()
  private maxConcurrent: number
  private maxPending: number
  private canDispatch: (() => boolean) | null

  constructor(maxConcurrent: number = 2, maxPending: number = 32,
    canDispatch: (() => boolean) | null = null) {
    this.maxConcurrent = Math.max(1, maxConcurrent)
    this.maxPending = Math.max(1, maxPending)
    this.canDispatch = canDispatch
  }

  enqueue(key: string, priority: number, runner: PreviewTaskRunner,
    recover: ((error: Object) => boolean) | null = null, valid: (() => boolean) | null = null,
    retryDelay: (() => number) | null = null): boolean {
    if (key.length === 0 || this.activeTasks.has(key)) {
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
      retryDelay: retryDelay,
      wanted: true
    })
    this.pump()
    return true
  }

  /** Promote a queued preload without replacing its runner or owner token. */
  promote(key: string, priority: number): boolean {
    const task = this.pending.find((item: PreviewTask): boolean => item.key === key) || this.activeTasks.get(key)
    if (task === undefined) {
      return false
    }
    task.priority = Math.min(task.priority, priority)
    task.wanted = true
    return true
  }

  /** Pause dispatch only. Running HTTP and server-readiness identities survive. */
  pause(): void {
    this.paused = true
    this.clearWakeTimer()
  }

  private clearWakeTimer(): void {
    if (this.wakeTimer > 0) { clearTimeout(this.wakeTimer); this.wakeTimer = 0 }
  }

  /** Reconcile once for a settled viewport, before admitting its visible tasks. */
  reconcile(priorities: Map<string, number>): string[] {
    const removed: string[] = []
    this.pending = this.pending.filter((task: PreviewTask): boolean => {
      const priority = priorities.get(task.key)
      if (priority === undefined) { removed.push(task.key); return false }
      task.priority = priority
      return true
    })
    this.activeTasks.forEach((task: PreviewTask): void => {
      const priority = priorities.get(task.key)
      task.wanted = priority !== undefined
      if (priority !== undefined) { task.priority = priority }
    })
    this.pause()
    return removed
  }

  /** Call after the visible batch is admitted, including an all-deferred batch. */
  resume(): void { this.paused = false; this.pump() }

  cancelPending(): string[] {
    this.readyWhileActive.clear()
    const keys = this.pending.map((task: PreviewTask): string => task.key)
    this.pending = []
    this.paused = false
    this.clearWakeTimer()
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
    else if (this.activeTasks.has(key)) { this.readyWhileActive.add(key) }
  }

  private pump(): void {
    this.clearWakeTimer()
    if (this.paused || (this.canDispatch !== null && !this.canDispatch())) { return }
    if (this.activeCount >= this.maxConcurrent) { return }
    this.pending.sort((left: PreviewTask, right: PreviewTask): number => {
      if (left.priority !== right.priority) { return left.priority - right.priority }
      return left.sequence - right.sequence
    })
    while (this.activeCount < this.maxConcurrent && this.pending.length > 0) {
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
      this.activeTasks.set(task.key, task)
      let retry = false
      task.runner().catch((error: Object): void => {
        // A thumbnail awaiting the server yields its worker to other files.
        // All deferred tasks share one timer and the original pending limit.
        if (task.wanted && task.recover !== null && task.recover(error) && task.retries < 5 &&
          (task.valid === null || task.valid()) && this.pending.length < this.maxPending) {
          const delay = task.retryDelay === null ? 0 : task.retryDelay()
          task.notBefore = Date.now() + (delay > 0 ? delay : 1000 * Math.pow(2, task.retries))
          task.retries++
          retry = true
        }
      }).finally((): void => {
        this.activeCount = Math.max(0, this.activeCount - 1)
        this.activeTasks.delete(task.key)
        const ready = this.readyWhileActive.delete(task.key)
        if (retry && task.wanted && (task.valid === null || task.valid()) && this.pending.length < this.maxPending) {
          if (ready) { task.notBefore = 0 }
          this.pending.push(task)
        }
        this.pump()
      })
    }
  }
}

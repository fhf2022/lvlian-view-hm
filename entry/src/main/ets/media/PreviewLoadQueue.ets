export type PreviewTaskRunner = () => Promise<void>

interface PreviewTask {
  key: string
  priority: number
  sequence: number
  runner: PreviewTaskRunner
}

/**
 * Small priority queue for visible thumbnails. It bounds work even when a
 * lazy container reports a burst of appearing items during a fast scroll.
 */
export class PreviewLoadQueue {
  private pending: PreviewTask[] = []
  private activeKeys: Record<string, boolean> = {}
  private activeCount: number = 0
  private sequence: number = 0
  private maxConcurrent: number
  private maxPending: number

  constructor(maxConcurrent: number = 2, maxPending: number = 32) {
    this.maxConcurrent = Math.max(1, maxConcurrent)
    this.maxPending = Math.max(1, maxPending)
  }

  enqueue(key: string, priority: number, runner: PreviewTaskRunner): boolean {
    if (key.length === 0 || this.activeKeys[key] === true ||
      this.pending.some((task: PreviewTask): boolean => task.key === key)) {
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
      runner: runner
    })
    this.pump()
    return true
  }

  cancelPending(): string[] {
    const keys = this.pending.map((task: PreviewTask): string => task.key)
    this.pending = []
    return keys
  }

  clear(): void {
    this.pending = []
  }

  activeCountValue(): number {
    return this.activeCount
  }

  pendingCount(): number {
    return this.pending.length
  }

  private pump(): void {
    while (this.activeCount < this.maxConcurrent && this.pending.length > 0) {
      this.pending.sort((left: PreviewTask, right: PreviewTask): number => {
        if (left.priority !== right.priority) {
          return left.priority - right.priority
        }
        return left.sequence - right.sequence
      })
      const task = this.pending.shift()
      if (task === undefined) {
        return
      }
      this.activeCount += 1
      this.activeKeys[task.key] = true
      task.runner().catch((): void => {
        // The caller owns error reporting. Queue failures must not stop the
        // remaining visible thumbnails from being processed.
      }).finally((): void => {
        this.activeCount = Math.max(0, this.activeCount - 1)
        this.activeKeys[task.key] = false
        this.pump()
      })
    }
  }
}

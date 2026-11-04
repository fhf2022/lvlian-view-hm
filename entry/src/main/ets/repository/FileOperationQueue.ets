import { FileEntry } from '../model/FileEntry'
import { DirectoryChange } from '../model/DirectoryChange'
import { FileOperationState, PendingFileOperation } from '../model/FileOperation'

/** One task-only timer and request. No directory traversal, file bytes or idle polling. */
export class FileOperationQueue {
  private pending: PendingFileOperation[] = []
  private timer: number = 0
  private running: boolean = false
  private foreground: boolean = true
  private generation: number = 0
  private read: () => Promise<FileOperationState[]>
  private exists: (path: string) => Promise<boolean>
  private identity: () => string
  private complete: (operation: PendingFileOperation, changes: DirectoryChange[], uncertain: boolean) => void

  constructor(read: () => Promise<FileOperationState[]>, exists: (path: string) => Promise<boolean>,
    identity: () => string,
    complete: (operation: PendingFileOperation, changes: DirectoryChange[], uncertain: boolean) => void) {
    this.read = read
    this.exists = exists
    this.identity = identity
    this.complete = complete
  }

  affectsDirectory(path: string): boolean {
    return this.pending.some((operation: PendingFileOperation): boolean => operation.affectedPaths.has(path))
  }

  canSubmit(): boolean { return this.pending.length < 16 }

  async prepare(entries: FileEntry[], target: string, move: boolean, rootType: number): Promise<PendingFileOperation> {
    if (!this.canSubmit()) { throw new Error('未完成的文件任务较多，请稍后重试') }
    const operation = new PendingFileOperation()
    operation.scope = this.identity()
    operation.entries = entries.map((entry: FileEntry): FileEntry => entry.clone())
    operation.target = target.replace(/\/+$/, '')
    operation.move = move
    operation.rootType = rootType
    operation.affectedPaths.add(operation.target)
    for (const entry of entries) {
      operation.affectedPaths.add(entry.path.substring(0, entry.path.lastIndexOf('/')))
    }
    await this.visit(operation, async (entry: FileEntry): Promise<void> => {
      const path = this.targetPath(operation, entry)
      if (await this.exists(path)) { operation.existingTargets.add(path) }
    })
    this.checkIdentity(operation)
    return operation
  }

  add(operation: PendingFileOperation): void {
    this.checkIdentity(operation)
    this.pending.push(operation)
    this.schedule(100)
  }

  setForeground(value: boolean): void {
    this.foreground = value
    if (this.timer > 0) { clearTimeout(this.timer); this.timer = 0 }
    if (value) { this.schedule(100) }
  }

  reset(): void {
    this.generation++
    this.pending = []
    if (this.timer > 0) { clearTimeout(this.timer); this.timer = 0 }
  }

  private checkIdentity(operation: PendingFileOperation): void {
    if (operation.scope === '' || operation.scope !== this.identity()) { throw new Error('账号已改变') }
  }

  private targetPath(operation: PendingFileOperation, entry: FileEntry): string {
    return operation.target + '/' + entry.name
  }

  private async visit(operation: PendingFileOperation, action: (entry: FileEntry) => Promise<void>): Promise<void> {
    let index = 0
    const worker = async (): Promise<void> => {
      while (index < operation.entries.length) {
        this.checkIdentity(operation)
        const entry = operation.entries[index++]
        await action(entry)
        this.checkIdentity(operation)
      }
    }
    // At most two metadata probes, even for a large multi-selection.
    await Promise.all([worker(), worker()])
  }

  private schedule(delay: number): void {
    if (!this.foreground || this.running || this.timer > 0 || this.pending.length === 0) { return }
    this.timer = setTimeout((): void => { this.timer = 0; this.poll() }, delay)
  }

  private async poll(): Promise<void> {
    if (this.running || !this.foreground || this.pending.length === 0) { return }
    const generation = this.generation
    this.running = true
    try {
      const states = await this.read()
      if (generation !== this.generation) { return }
      for (const operation of this.pending.slice()) {
        if (operation.scope !== this.identity()) {
          this.pending = this.pending.filter((item: PendingFileOperation): boolean => item !== operation)
          continue
        }
        const state = states.find((item: FileOperationState): boolean => item.id === operation.id)
        operation.missingChecks = state === undefined ? operation.missingChecks + 1 : 0
        const expired = Date.now() - operation.startedAt > 30 * 60 * 1000
        const missing = operation.missingChecks >= 5
        if (state !== undefined && state.complete) {
          const changes = await this.confirm(operation)
          if (generation !== this.generation) { return }
          this.checkIdentity(operation)
          this.pending = this.pending.filter((item: PendingFileOperation): boolean => item !== operation)
          this.complete(operation, changes, state.failed)
        } else if (state === undefined && (expired || missing)) {
          this.pending = this.pending.filter((item: PendingFileOperation): boolean => item !== operation)
          this.complete(operation, [], true)
        }
      }
    } catch (_) {
      // A failed read never proves a move. Keep source rows and retry metadata only.
      if (generation === this.generation) {
        const expired = this.pending.filter((item: PendingFileOperation): boolean =>
          Date.now() - item.startedAt > 30 * 60 * 1000)
        this.pending = this.pending.filter((item: PendingFileOperation): boolean => expired.indexOf(item) < 0)
        for (const operation of expired) {
          if (operation.scope === this.identity()) { this.complete(operation, [], true) }
        }
      }
    } finally {
      this.running = false
      const oldest = this.pending.length > 0 ? this.pending[0].startedAt : Date.now()
      this.schedule(Date.now() - oldest < 10000 ? 1000 : 5000)
    }
  }

  private async confirm(operation: PendingFileOperation): Promise<DirectoryChange[]> {
    const changes = new Map<string, DirectoryChange>()
    const changeAt = (path: string): DirectoryChange => {
      let change = changes.get(path)
      if (change === undefined) { change = new DirectoryChange(path); changes.set(path, change) }
      return change
    }
    await this.visit(operation, async (entry: FileEntry): Promise<void> => {
      const target = this.targetPath(operation, entry)
      if (!await this.exists(target)) { return }
      if (operation.move) {
        if (await this.exists(entry.path)) { return } // skipped/cancelled/partial, not moved
        changeAt(entry.path.substring(0, entry.path.lastIndexOf('/'))).removals.push(entry.path)
      }
      if (!operation.existingTargets.has(target)) {
        const added = entry.clone()
        added.path = target
        added.rootType = operation.rootType
        added.thumbnailUrl = ''
        added.coverUrl = ''
        changeAt(operation.target).additions.push(added)
      }
    })
    return Array.from(changes.values())
  }
}

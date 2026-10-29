import { FileEntry } from '../model/FileEntry'
import { ViewerBitmapMetadata } from './ViewerBitmapStore'
import { DownloadCancellation } from '../core/network/DownloadCancellation'

export type WaterfallBatchChange = 'initial' | 'append' | 'prepend' | 'resident'
type BatchPhase = 'preparing' | 'ready' | 'originals' | 'complete' | 'failed'

export interface WaterfallBatchDelegate {
  geometry: (entry: FileEntry, valid: () => boolean, cancellation: DownloadCancellation) => Promise<ViewerBitmapMetadata | null>
  layout?: (entry: FileEntry, info: ViewerBitmapMetadata | null) => void
  thumbnail: (entry: FileEntry, valid: () => boolean) => Promise<void>
  publish: (change: WaterfallBatchChange) => void
  originals: (entries: FileEntry[], retry: boolean) => void
  evict: (entries: FileEntry[]) => void
  changed: () => void
  canEvict?: (entries: FileEntry[]) => boolean
}

class Batch {
  index: number
  entries: FileEntry[]
  geometry: (ViewerBitmapMetadata | null)[] = []
  phase: BatchPhase = 'preparing'
  completed: Set<string> = new Set<string>()
  failed: Set<string> = new Set<string>()
  constructor(index: number, entries: FileEntry[]) { this.index = index; this.entries = entries }
}

/** Staged admission, independent of native cells. Geometry survives resource
 * eviction; only a prepared group can extend the native scrolling content. */
export class WaterfallBatchCoordinator {
  static readonly SIZE: number = 12
  static readonly MAX_RESIDENT_GROUPS: number = 4
  first: number = -1
  last: number = -1
  focus: number = 0
  preparing: number = -1
  error: boolean = false
  private session: number = 0
  private hidden: boolean = false
  private entries: FileEntry[] = []
  private batches: Map<number, Batch> = new Map<number, Batch>()
  private residents: Set<number> = new Set<number>()
  private pending: number = -1
  private jump: number = -1
  private admittedEnd: number = 0
  private preparation: Promise<void> = Promise.resolve()
  private waiters: Map<number, (() => void)[]> = new Map<number, (() => void)[]>()
  private delegate: WaterfallBatchDelegate
  private direction: number = 1
  private staged: number = -1
  private preparationCancellation: DownloadCancellation = new DownloadCancellation()

  constructor(delegate: WaterfallBatchDelegate) { this.delegate = delegate }

  reset(entries: FileEntry[] = [], initialIndex: number = 0): void {
    this.preparationCancellation.cancel()
    this.session++; this.hidden = false; this.entries = entries; this.batches.clear(); this.residents.clear()
    this.first = -1; this.last = -1; this.preparing = -1; this.error = false
    this.focus = Math.max(0, Math.floor(initialIndex / WaterfallBatchCoordinator.SIZE))
    this.pending = -1; this.jump = this.focus; this.admittedEnd = 0
    this.direction = 1; this.staged = -1
    this.waiters.forEach((callbacks: (() => void)[]): void => callbacks.forEach((callback: () => void): void => callback()))
    this.waiters.clear()
    if (entries.length > 0) { this.request(this.focus) }
  }

  sync(entries: FileEntry[]): void {
    this.entries = entries
    if (this.first < 0) { if (entries.length > 0 && this.preparing < 0) { this.request(this.focus) }; return }
    const tail = this.batches.get(this.last)
    if (tail !== undefined) {
      const next = this.groupEntries(tail.index)
      if (next.length > tail.entries.length) { this.refreshEntries(tail, next); return }
    }
    const staged = this.batches.get(this.staged)
    if (staged !== undefined && !this.residents.has(staged.index)) {
      const next = this.groupEntries(staged.index)
      if (next.length > staged.entries.length) { this.refreshEntries(staged, next); return }
    }
    this.advance()
  }

  private refreshEntries(batch: Batch, entries: FileEntry[]): void {
    batch.entries = entries
    const pending = this.pending
    this.preparationCancellation.cancel()
    this.preparing = -1
    this.request(batch.index, true, !this.residents.has(batch.index))
    if (pending >= 0 && pending !== batch.index) { this.pending = pending }
  }

  setHidden(hidden: boolean): void { this.hidden = hidden; if (!hidden) { this.advance() } }

  visible(firstIndex: number, lastIndex: number): void {
    if (this.hidden) { return }
    const next = Math.floor(Math.max(0, firstIndex) / WaterfallBatchCoordinator.SIZE)
    if (this.residents.has(next) && next !== this.focus) {
      this.direction = next > this.focus ? 1 : -1
      this.focus = next
      this.delegate.originals(this.originalTargets(), false)
      this.advance()
    } else if (this.pending >= 0) { this.advance() }
  }

  edge(direction: number): void {
    this.direction = direction < 0 ? -1 : 1
    const target = direction < 0 ? this.residentFirst() - 1 : this.residentLast() + 1
    if (this.hasGroup(target)) { this.pending = target; this.advance() }
  }

  async ensure(index: number): Promise<void> {
    const group = Math.floor(index / WaterfallBatchCoordinator.SIZE)
    if (!this.hasGroup(group)) { return }
    if (this.residents.has(group) && this.localIndex(index) >= 0 && this.batches.get(group)?.phase !== 'preparing') {
      this.focus = group
      return
    }
    this.jump = group; this.pending = group
    // Timeline scrubbing replaces a pending destination; do not retain a
    // promise/closure for every day the finger crossed.
    this.waiters.forEach((callbacks: (() => void)[], target: number): void => {
      if (target !== group) {
        this.waiters.delete(target)
        callbacks.forEach((callback: () => void): void => callback())
      }
    })
    const waiting = new Promise<void>((resolve): void => {
      const callbacks = this.waiters.get(group) ?? []
      callbacks.push(resolve); this.waiters.set(group, callbacks)
    })
    this.request(group, this.residents.has(group) && this.localIndex(index) < 0)
    await waiting
  }

  retry(): void {
    this.error = false
    let batch = this.batches.get(this.pending >= 0 ? this.pending : this.focus)
    for (const group of Array.from(this.residents)) {
      const candidate = this.batches.get(group)
      if (candidate?.failed.size) { batch = candidate; break }
    }
    if (batch === undefined || !this.residents.has(batch.index) ||
      !batch.entries.every((_entry: FileEntry, index: number): boolean => batch?.geometry[index] !== undefined)) {
      this.request(this.pending >= 0 ? this.pending : this.focus, true); return
    }
    batch.failed.clear(); batch.phase = 'originals'
    this.delegate.originals(this.originalTargets(), true); this.delegate.changed()
  }

  originalFinished(entry: FileEntry, success: boolean): void {
    // A request holds a clone; inspect only the bounded resident window.
    let batch: Batch | undefined = undefined
    for (const group of Array.from(this.residents)) {
      const candidate = this.batches.get(group)
      if (candidate?.entries.some((item: FileEntry): boolean => item.path === entry.path)) { batch = candidate; break }
    }
    if (batch === undefined) { return }
    if (success) { batch.completed.add(entry.path); batch.failed.delete(entry.path) }
    else { batch.failed.add(entry.path) }
    if (batch.phase === 'preparing') { return }
    const ready = batch.entries.every((item: FileEntry, offset: number): boolean =>
      batch?.geometry[offset] === null || batch?.completed.has(item.path) === true)
    if (ready) { batch.phase = 'complete'; this.error = this.hasActiveFailure(); this.delegate.changed(); this.advance() }
    else if (!success) { batch.phase = 'failed'; this.error = this.hasActiveFailure(); this.delegate.changed() }
  }

  localIndex(index: number): number {
    if (this.first < 0 || index < this.first * WaterfallBatchCoordinator.SIZE || index >= this.admittedEnd) { return -1 }
    return index - this.first * WaterfallBatchCoordinator.SIZE
  }
  absoluteIndex(index: number): number { return Math.max(0, this.first) * WaterfallBatchCoordinator.SIZE + index }
  published(): FileEntry[] { return this.first < 0 ? [] : this.entries.slice(this.first * WaterfallBatchCoordinator.SIZE, this.admittedEnd) }
  resident(index: number): boolean { return this.residents.has(Math.floor(index / WaterfallBatchCoordinator.SIZE)) }
  residentGroups(): number[] { return Array.from(this.residents) }
  residentFirst(): number {
    const groups = Array.from(this.residents).filter((group: number): boolean => group >= this.first && group <= this.last)
    let group = groups.indexOf(this.focus) >= 0 ? this.focus : (groups[0] ?? this.focus)
    while (groups.indexOf(group - 1) >= 0) { group-- }
    return group
  }
  residentLast(): number {
    const groups = Array.from(this.residents).filter((group: number): boolean => group >= this.first && group <= this.last)
    let group = groups.indexOf(this.focus) >= 0 ? this.focus : (groups[0] ?? this.focus)
    while (groups.indexOf(group + 1) >= 0) { group++ }
    return group
  }
  info(index: number): ViewerBitmapMetadata | null | undefined { return this.batches.get(Math.floor(index / WaterfallBatchCoordinator.SIZE))?.geometry[index % WaterfallBatchCoordinator.SIZE] }
  hasNext(): boolean { return this.hasGroup(this.last + 1) }
  hasPrevious(): boolean { return this.first > 0 }
  waiting(): boolean {
    return (this.first < 0 && this.preparing >= 0) ||
      (this.pending >= 0 && !this.residents.has(this.pending))
  }

  private hasGroup(index: number): boolean { return index >= 0 && index * WaterfallBatchCoordinator.SIZE < this.entries.length }
  private groupEntries(index: number): FileEntry[] { return this.entries.slice(index * WaterfallBatchCoordinator.SIZE, (index + 1) * WaterfallBatchCoordinator.SIZE) }

  private hasActiveFailure(): boolean {
    if (this.batches.get(this.pending)?.phase === 'failed') { return true }
    const first = this.residentFirst(); const last = this.residentLast()
    return Array.from(this.residents).some((group: number): boolean =>
      group >= first && group <= last && this.batches.get(group)?.phase === 'failed')
  }

  private originalTargets(): FileEntry[] {
    const result: FileEntry[] = []
    const groups = Array.from(this.residents).sort((a: number, b: number): number => Math.abs(a - this.focus) - Math.abs(b - this.focus))
    for (const group of groups) {
      const batch = this.batches.get(group)
      if (batch === undefined || batch.phase === 'preparing') { continue }
      batch.entries.forEach((entry: FileEntry, index: number): void => { if (batch.geometry[index] !== null) { result.push(entry) } })
    }
    return result
  }

  private advance(): void {
    if (this.preparing >= 0 || (this.hidden && this.jump < 0)) { return }
    if (this.pending >= 0 && !this.residents.has(this.pending)) { this.request(this.pending); return }
    if (this.error || this.first < 0) { return }
    const target = this.direction < 0 ? this.residentFirst() - 1 : this.residentLast() + 1
    if (this.hasGroup(target) && this.batches.get(target)?.phase !== 'ready' &&
      this.batches.get(target)?.phase !== 'failed') { this.request(target, false, true) }
  }

  private request(group: number, refresh: boolean = false, stageOnly: boolean = false): void {
    if (!this.hasGroup(group)) { return }
    if (this.preparing >= 0) { if (this.preparing !== group) { this.pending = group }; return }
    if (!refresh && this.residents.has(group)) { return }
    let batch = this.batches.get(group)
    if (!refresh && batch?.phase === 'ready') {
      if (!stageOnly) { this.admit(batch) }
      return
    }
    if (stageOnly && this.staged >= 0 && this.staged !== group && !this.residents.has(this.staged)) {
      const old = this.batches.get(this.staged)
      if (old?.phase === 'ready' && (this.staged < this.first || this.staged > this.last)) {
        this.batches.delete(this.staged)
      }
    }
    if (batch === undefined) { batch = new Batch(group, this.groupEntries(group)); this.batches.set(group, batch) }
    if (!this.residents.has(group)) { batch.completed.clear(); batch.failed.clear() }
    batch.phase = 'preparing'; this.preparing = group
    if (stageOnly) { this.staged = group } else { this.pending = group; this.error = false }
    this.preparationCancellation = new DownloadCancellation()
    this.delegate.changed()
    const current = batch
    const session = this.session
    // A reset cannot release native IO slots which are still finishing.
    this.preparation = this.preparation.catch((): void => {}).then(async (): Promise<void> => {
      if (session === this.session && this.preparing === current.index) { await this.prepare(current, session, stageOnly) }
    })
  }

  private async prepare(batch: Batch, session: number, stageOnly: boolean): Promise<void> {
    const cancellation = this.preparationCancellation
    const valid = (): boolean => session === this.session && this.preparing === batch.index && !cancellation.isCancelled()
    try {
      let cursor = 0
      let geometryFailed = false
      const geometryWorker = async (): Promise<void> => {
        while (valid() && !geometryFailed && cursor < batch.entries.length) {
          const index = cursor++
          if (batch.geometry[index] === undefined) {
            try {
              const geometry = await this.delegate.geometry(batch.entries[index], valid, cancellation)
              if (valid()) { batch.geometry[index] = geometry }
            } catch (_) { geometryFailed = true }
          }
          if (valid() && batch.geometry[index] !== undefined) {
            this.delegate.layout?.(batch.entries[index], batch.geometry[index])
          }
        }
      }
      await Promise.all([geometryWorker(), geometryWorker()])
      if (!valid()) { return }
      if (geometryFailed) { throw new Error('Original geometry unavailable') }
      cursor = 0
      const thumbnailWorker = async (): Promise<void> => {
        while (valid() && cursor < batch.entries.length) {
          const index = cursor++
          if (batch.geometry[index] !== null) { try { await this.delegate.thumbnail(batch.entries[index], valid) } catch (_) {} }
        }
      }
      await Promise.all([thumbnailWorker(), thumbnailWorker()])
      if (!valid()) { return }
      batch.phase = 'ready'; this.preparing = -1
      if (!stageOnly || this.pending === batch.index || this.jump === batch.index) { this.admit(batch) }
      else { this.delegate.changed(); this.advance() }
    } catch (_) {
      if (valid()) {
        this.preparing = -1; this.error = !stageOnly || this.pending === batch.index; batch.phase = 'failed'; this.delegate.changed()
        const callbacks = this.waiters.get(batch.index) ?? []; this.waiters.delete(batch.index)
        callbacks.forEach((callback: () => void): void => callback())
      }
    }
  }

  private admit(batch: Batch): void {
    const group = batch.index
    if (this.residents.size >= WaterfallBatchCoordinator.MAX_RESIDENT_GROUPS && !this.residents.has(group)) {
      const edge = group < this.residentFirst() ? Math.max(...Array.from(this.residents)) : Math.min(...Array.from(this.residents))
      const candidates = Array.from(this.residents).filter((index: number): boolean =>
        index !== this.focus && (this.jump === group || index === edge ||
          index < this.residentFirst() || index > this.residentLast()) &&
        (this.jump === group || this.delegate.canEvict?.(this.batches.get(index)?.entries ?? []) !== false))
      candidates.sort((a: number, b: number): number => Math.abs(b - group) - Math.abs(a - group))
      if (candidates.length === 0) { this.pending = group; return }
      const evicted = candidates[0]; this.residents.delete(evicted)
      this.delegate.evict(this.batches.get(evicted)?.entries ?? [])
    }
    const oldFirst = this.first; const oldLast = this.last
    const outside = this.first < 0 || batch.index < this.first - 1 || batch.index > this.last + 1
    if (outside) { this.first = batch.index; this.last = batch.index; this.focus = batch.index }
    else { this.first = Math.min(this.first, batch.index); this.last = Math.max(this.last, batch.index) }
    if (this.jump === batch.index) { this.focus = batch.index }
    this.residents.add(batch.index); batch.phase = 'originals'
    this.admittedEnd = Math.min(this.entries.length, (this.last + 1) * WaterfallBatchCoordinator.SIZE)
    if (this.pending === batch.index) { this.pending = -1 }; if (this.jump === batch.index) { this.jump = -1 }
    const change: WaterfallBatchChange = outside ? 'initial' : (this.first < oldFirst ? 'prepend' : (this.last > oldLast ? 'append' : 'resident'))
    this.delegate.publish(change)
    this.delegate.originals(this.originalTargets(), false)
    const callbacks = this.waiters.get(batch.index) ?? []; this.waiters.delete(batch.index)
    callbacks.forEach((callback: () => void): void => callback())
    // Re-entering an already resident far destination can reuse completed
    // requests. They will not emit another download completion callback.
    if (batch.entries.every((entry: FileEntry, index: number): boolean =>
      batch.geometry[index] === null || batch.completed.has(entry.path))) {
      batch.phase = 'complete'
    } else if (batch.failed.size > 0) {
      batch.phase = 'failed'; this.error = this.hasActiveFailure()
    }
    this.delegate.changed()
    this.advance()
  }
}

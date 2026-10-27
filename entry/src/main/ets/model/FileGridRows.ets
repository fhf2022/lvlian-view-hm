import { FileEntry } from './FileEntry'
import { FileEntryDataSource } from './FileEntryDataSource'

@Observed
export class FileGridRow {
  start: number = 0
  key: string = ''
  entries: FileEntry[] = []
}

/** Lazy presentation adapter. The original file datasource remains authoritative. */
export class FileGridRows implements IDataSource, DataChangeListener {
  columns: number = 2
  private cache: Map<number, FileGridRow> = new Map()
  private listeners: DataChangeListener[] = []
  private source: FileEntryDataSource
  private epoch: number = 0
  private count: number = 0
  private files: number = 0
  constructor(source: FileEntryDataSource) { this.source = source; source.registerDataChangeListener(this) }

  configure(columns: number): void {
    if (columns === this.columns) { return }
    this.columns = Math.max(1, columns); this.onDataReloaded()
  }
  totalCount(): number { return Math.ceil(this.source.totalCount() / this.columns) }
  nativeIndex(index: number): number { return Math.floor(index / this.columns) }
  fileIndex(row: number, column: number): number {
    const index = row * this.columns + column
    return row >= 0 && column >= 0 && column < this.columns && index < this.source.totalCount() ? index : -1
  }
  rowKey(index: number): string { return this.epoch + ':' + index * this.columns }
  getData(index: number): FileGridRow {
    let row = this.cache.get(index)
    if (row === undefined) {
      row = new FileGridRow(); row.start = index * this.columns
      row.key = this.rowKey(index)
      this.cache.set(index, row)
    } else { this.cache.delete(index); this.cache.set(index, row) }
    const entries: FileEntry[] = []
    const length = Math.min(this.columns, this.source.totalCount() - row.start)
    for (let offset = 0; offset < length; offset++) {
      entries.push(this.source.getData(row.start + offset))
    }
    // Thumbnail revisions are observed by each original FileGridCell. Updating
    // only membership avoids rebuilding an entire row when one image is ready.
    const previousEntries = row.entries
    if (entries.length !== previousEntries.length || entries.some((entry: FileEntry, offset: number): boolean => entry !== previousEntries[offset])) {
      row.entries = entries
    }
    // This is a bounded descriptor cache, not an additional bitmap cache.
    while (this.cache.size > 128) { this.cache.delete(Array.from(this.cache.keys())[0]) }
    return row
  }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener) }
    this.count = this.totalCount(); this.files = this.source.totalCount()
  }
  unregisterDataChangeListener(listener: DataChangeListener): void { this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener) }
  onDataReloaded(): void {
    this.epoch++; this.cache.clear(); this.count = this.totalCount()
    this.files = this.source.totalCount()
    for (const listener of this.listeners) { listener.onDataReloaded() }
  }
  onDataChange(index: number): void {
    const row = this.nativeIndex(index)
    if (this.cache.has(row)) { this.getData(row) }
    for (const listener of this.listeners) { listener.onDataChange(row) }
  }
  onDataAdd(index: number): void {
    const files = this.source.totalCount()
    // Source append publishes the whole page before emitting one callback per
    // file. Process the count change once, including the old partial last row.
    if (files === this.files) { return }
    const oldFiles = this.files; this.files = files
    const next = this.totalCount()
    if (index < oldFiles) { this.onDataReloaded(); return }
    if (oldFiles % this.columns !== 0) { this.onDataChange(oldFiles - 1) }
    const previous = this.count; this.count = next
    for (let row = previous; row < next; row++) {
      for (const listener of this.listeners) { listener.onDataAdd(row) }
    }
  }
  onDataDelete(_index: number): void { this.onDataReloaded() }
  onDataMove(_from: number, _to: number): void { this.onDataReloaded() }
  onDataAdded(index: number): void { this.onDataAdd(index) }
  onDataDeleted(index: number): void { this.onDataDelete(index) }
  onDataMoved(from: number, to: number): void { this.onDataMove(from, to) }
  onDataChanged(index: number): void { this.onDataChange(index) }
  onDatasetChange(_operations: DataOperation[]): void { this.onDataReloaded() }
}

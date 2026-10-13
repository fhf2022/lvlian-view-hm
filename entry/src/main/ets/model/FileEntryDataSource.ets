import { hilog } from '@kit.PerformanceAnalysisKit'
import { FileEntry } from './FileEntry'

// Detailed per-build probes are opt-in; string formatting and hilog otherwise
// run for every recycled image during a fling.
export const THUMB_PROBE: boolean = false

/** IDataSource adapter used by List, Grid and other lazy containers. */
export class FileEntryDataSource implements IDataSource {
  private items: FileEntry[] = []
  private pathIndexes: Map<string, number> = new Map<string, number>()
  private listeners: DataChangeListener[] = []
  onItemRequested: ((index: number, entry: FileEntry) => void) | null = null
  /**
   * R2 原型：@Observed + @ObjectLink 依赖「同一个实例被就地修改」来通知子组件。
   * 一旦 clone 出新实例，已挂载 cell 手里的旧实例就永远收不到通知，
   * 所以 R2 模式下必须就地自增 previewRevision，不能换实例。
   */
  bumpInPlace: boolean = false

  constructor(items: FileEntry[] = []) {
    this.items = items.slice()
    this.rebuildPathIndexes()
  }

  totalCount(): number {
    return this.items.length
  }

  getData(index: number): FileEntry {
    const item = this.items[index]
    if (this.onItemRequested !== null) {
      this.onItemRequested(index, item)
    }
    if (THUMB_PROBE) {
      hilog.info(0xD003, 'ThumbProbe', `[4-getData] index=${index}, path=${item ? item.path : ''}, rev=${item ? item.previewRevision : 0}`)
    }
    return item
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener)
    if (index >= 0) {
      this.listeners.splice(index, 1)
    }
  }

  /**
   * 实验 H0 / 单 Cell 刷新：
   * 更新指定索引的数据对象与 previewRevision，并通知 LazyForEach 局部重建/更新对应 Item。
   */
  notifyItemChanged(index: number): void {
    if (index >= 0 && index < this.items.length) {
      if (this.bumpInPlace) {
        // R2 原型路径：就地改同一个实例的版本号。
        // @ObjectLink 的 cell 会因此局部重算；不产生新实例，不动任何 @State。
        const item = this.items[index]
        item.previewRevision = (item.previewRevision || 0) + 1
        if (THUMB_PROBE) {
          hilog.info(0xD003, 'ThumbProbe', `[3-notifyItemChanged-R2] index=${index}, path=${item.path}, rev=${item.previewRevision}, listeners=${this.listeners.length}`)
        }
        for (const listener of this.listeners.slice()) {
          listener.onDataChange(index)
        }
        return
      }
      const oldItem = this.items[index]
      const newItem = oldItem.clone()
      newItem.previewRevision = (oldItem.previewRevision || 0) + 1
      this.items[index] = newItem
      if (THUMB_PROBE) {
        hilog.info(0xD003, 'ThumbProbe', `[3-notifyItemChanged] index=${index}, path=${newItem.path}, rev=${newItem.previewRevision}, listeners=${this.listeners.length}`)
      }
      for (const listener of this.listeners.slice()) {
        if (THUMB_PROBE) {
          hilog.info(0xD003, 'ThumbProbe', `[3b-onDataChange] notifying listener.onDataChange(${index})`)
        }
        listener.onDataChange(index)
      }
    }
  }

  /**
   * 快速定位 path 对应的当前 index。
   */
  indexOfPath(path: string): number {
    const index = this.pathIndexes.get(path)
    return index === undefined ? -1 : index
  }

  private rebuildPathIndexes(): void {
    this.pathIndexes.clear()
    for (let index = 0; index < this.items.length; index++) {
      if (!this.pathIndexes.has(this.items[index].path)) {
        this.pathIndexes.set(this.items[index].path, index)
      }
    }
  }

  replace(items: FileEntry[]): void {
    const previousItems = this.items
    const nextItems = items.slice()
    // Always publish the newest descriptors to future lazy items, but keep
    // mounted rows intact when only volatile NAS URLs or integrity metadata
    // changed. Signed thumbnail URLs can change on every directory refresh;
    // notifying those rows would rebuild their Image nodes and briefly expose
    // the previous directory during a page transition.
    if (this.samePathOrder(nextItems)) {
      const changedIndexes: number[] = []
      for (let index = 0; index < nextItems.length; index++) {
        if (!this.sameRenderedEntry(previousItems[index], nextItems[index])) {
          changedIndexes.push(index)
        }
        if (this.bumpInPlace) {
          // @ObjectLink still owns this exact instance. Replacing it while
          // skipping a reload strands the mounted cell on the old object.
          previousItems[index].updateFrom(nextItems[index])
          nextItems[index] = previousItems[index]
        }
      }
      this.items = nextItems
      for (const listener of this.listeners.slice()) {
        for (const index of changedIndexes) {
          listener.onDataChange(index)
        }
      }
      return
    }

    this.items = nextItems
    this.rebuildPathIndexes()
    for (const listener of this.listeners.slice()) {
      listener.onDataReloaded()
    }
  }

  append(items: FileEntry[]): void {
    if (items.length === 0) {
      return
    }
    const startIndex = this.items.length
    for (const item of items) {
      if (!this.pathIndexes.has(item.path)) {
        this.pathIndexes.set(item.path, this.items.length)
      }
      this.items.push(item)
    }
    for (let index = 0; index < items.length; index++) {
      for (const listener of this.listeners.slice()) {
        listener.onDataAdd(startIndex + index)
      }
    }
  }

  /**
   * 在指定位置插入一条，并且【只通知这一个索引】（onDataAdd）。
   * 不要用 replace() 来做插入：新文件会改变 path 顺序 → replace 会退化成
   * onDataReloaded() 全量重载 → 所有已挂载行被销毁重建（闪烁 + 上下位移）。
   */
  insertAt(index: number, item: FileEntry): void {
    const target = Math.max(0, Math.min(index, this.items.length))
    this.items.splice(target, 0, item)
    this.rebuildPathIndexes()
    for (const listener of this.listeners.slice()) {
      listener.onDataAdd(target)
    }
  }

  private samePathOrder(nextItems: FileEntry[]): boolean {
    if (this.items.length !== nextItems.length) {
      return false
    }
    for (let index = 0; index < nextItems.length; index++) {
      if (this.items[index].path !== nextItems[index].path) {
        return false
      }
    }
    return true
  }

  private sameRenderedEntry(left: FileEntry, right: FileEntry): boolean {
    return left.path === right.path &&
      left.name === right.name &&
      left.isDirectory === right.isDirectory &&
      left.size === right.size &&
      left.modifiedTime === right.modifiedTime &&
      left.createdTime === right.createdTime &&
      left.childCount === right.childCount &&
      left.rootType === right.rootType &&
      left.intranetShareId === right.intranetShareId &&
      left.mimeType === right.mimeType
  }
}

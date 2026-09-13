import { FileEntry } from './FileEntry'

/** IDataSource adapter used by List, Grid and other lazy containers. */
export class FileEntryDataSource implements IDataSource {
  private items: FileEntry[] = []
  private listeners: DataChangeListener[] = []

  constructor(items: FileEntry[] = []) {
    this.items = items.slice()
  }

  totalCount(): number {
    return this.items.length
  }

  getData(index: number): FileEntry {
    return this.items[index]
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

  replace(items: FileEntry[]): void {
    const previousItems = this.items
    const nextItems = items.slice()
    // Always publish the newest descriptors to future lazy items, but keep
    // mounted rows intact when only volatile NAS URLs or integrity metadata
    // changed. Signed thumbnail URLs can change on every directory refresh;
    // notifying those rows would rebuild their Image nodes and briefly expose
    // the previous directory during a page transition.
    if (this.samePathOrder(nextItems)) {
      this.items = nextItems
      const changedIndexes: number[] = []
      for (let index = 0; index < nextItems.length; index++) {
        if (!this.sameRenderedEntry(previousItems[index], nextItems[index])) {
          changedIndexes.push(index)
        }
      }
      for (const listener of this.listeners.slice()) {
        for (const index of changedIndexes) {
          listener.onDataChange(index)
        }
      }
      return
    }

    this.items = nextItems
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
      this.items.push(item)
    }
    for (let index = 0; index < items.length; index++) {
      for (const listener of this.listeners.slice()) {
        listener.onDataAdd(startIndex + index)
      }
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

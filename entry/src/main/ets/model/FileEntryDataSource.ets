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
    this.items = items.slice()
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
}

export class ByteRange {
  start: number = 0
  end: number = 0

  constructor(start: number = 0, end: number = 0) {
    this.start = Math.max(0, Math.floor(start))
    this.end = Math.max(this.start, Math.floor(end))
  }
}

/**
 * Stores the union of downloaded byte intervals. A sparse file's stat.size is
 * the highest written offset, not the amount of valid media, so progress and
 * completeness must use this interval union instead.
 */
export class ByteRangeStore {
  private ranges: ByteRange[] = []

  clear(): void {
    this.ranges = []
  }

  load(serialized: string[]): void {
    this.clear()
    for (const value of serialized) {
      const dash = value.indexOf('-')
      if (dash <= 0) {
        continue
      }
      const start = Number(value.substring(0, dash))
      const end = Number(value.substring(dash + 1))
      if (Number.isFinite(start) && Number.isFinite(end) && end > start) {
        this.add(start, end)
      }
    }
  }

  add(start: number, end: number): void {
    const safeStart = Math.max(0, Math.floor(start))
    const safeEnd = Math.max(safeStart, Math.floor(end))
    if (safeEnd <= safeStart) {
      return
    }
    const merged: ByteRange[] = []
    let pending = new ByteRange(safeStart, safeEnd)
    let inserted = false
    for (const current of this.ranges) {
      if (current.end < pending.start) {
        merged.push(new ByteRange(current.start, current.end))
        continue
      }
      if (pending.end < current.start) {
        if (!inserted) {
          merged.push(new ByteRange(pending.start, pending.end))
          inserted = true
        }
        merged.push(new ByteRange(current.start, current.end))
        continue
      }
      pending = new ByteRange(Math.min(pending.start, current.start),
        Math.max(pending.end, current.end))
    }
    if (!inserted) {
      merged.push(pending)
    }
    this.ranges = merged
  }

  contains(start: number, end: number): boolean {
    const safeStart = Math.max(0, Math.floor(start))
    const safeEnd = Math.max(safeStart, Math.floor(end))
    for (const range of this.ranges) {
      if (range.start <= safeStart && range.end >= safeEnd) {
        return true
      }
      if (range.start > safeStart) {
        return false
      }
    }
    return false
  }

  coveredBytes(): number {
    let total = 0
    for (const range of this.ranges) {
      total += Math.max(0, range.end - range.start)
    }
    return total
  }

  complete(totalBytes: number): boolean {
    return totalBytes > 0 && this.contains(0, totalBytes)
  }

  nextMissing(start: number, end: number): ByteRange | null {
    const safeStart = Math.max(0, Math.floor(start))
    const safeEnd = Math.max(safeStart, Math.floor(end))
    if (safeEnd <= safeStart) {
      return null
    }
    let cursor = safeStart
    for (const range of this.ranges) {
      if (range.end <= cursor) {
        continue
      }
      if (range.start > cursor) {
        return new ByteRange(cursor, Math.min(range.start, safeEnd))
      }
      cursor = Math.max(cursor, range.end)
      if (cursor >= safeEnd) {
        return null
      }
    }
    return cursor < safeEnd ? new ByteRange(cursor, safeEnd) : null
  }

  serialize(): string[] {
    return this.ranges.map((range: ByteRange): string =>
      range.start.toString() + '-' + range.end.toString())
  }
}

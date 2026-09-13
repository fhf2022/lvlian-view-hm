import { FileEntry } from './FileEntry'

export type DirectorySortKey = 'name' | 'type' | 'time' | 'size'
export type DirectoryMediaFilter = 'all' | 'images' | 'videos' | 'media'
export type TimelinePeriod = 'day' | 'month' | 'year'

export class DirectoryQuery {
  path: string = ''
  rootType: number = 3
  sortKey: DirectorySortKey = 'time'
  ascending: boolean = false
  mediaFilter: DirectoryMediaFilter = 'all'
  dateFrom: number = 0
  dateTo: number = 0
}

export class TimelineDayBucket {
  dayStart: number = 0
  count: number = 0
}

export class DirectoryTimeline {
  complete: boolean = false
  directImageCount: number = 0
  earliestTime: number = 0
  latestTime: number = 0
  buckets: TimelineDayBucket[] = []

  eligible(minimumImageCount: number = DirectoryTimelinePolicy.MINIMUM_IMAGE_COUNT): boolean {
    return this.complete &&
      this.directImageCount >= minimumImageCount &&
      this.latestTime - this.earliestTime >= DirectoryTimelinePolicy.MINIMUM_SPAN_MS
  }
}

export class DirectoryIndexedSnapshot {
  entries: FileEntry[] = []
  fetchedAt: number = 0
  totalCount: number = 0
  timeline: DirectoryTimeline = new DirectoryTimeline()
  contentSignature: string = ''
}

export class DirectoryTimelineLocation {
  path: string = ''
  entryIndex: number = -1
  dayStart: number = 0
}

/**
 * Pure metadata policy shared by the RDB index, repository queries and UI.
 * Building an index never opens a thumbnail or downloads the original file.
 */
export class DirectoryTimelinePolicy {
  static readonly MINIMUM_IMAGE_COUNT: number = 80
  static readonly DAY_MS: number = 24 * 60 * 60 * 1000
  static readonly MINIMUM_SPAN_MS: number = 30 * DirectoryTimelinePolicy.DAY_MS

  static minimumImageCount(visibleImageCount: number): number {
    return Math.max(DirectoryTimelinePolicy.MINIMUM_IMAGE_COUNT,
      Math.max(0, visibleImageCount) * 6)
  }

  static build(entries: FileEntry[], complete: boolean = true): DirectoryTimeline {
    const timeline = new DirectoryTimeline()
    timeline.complete = complete
    const buckets: Map<number, number> = new Map<number, number>()
    let earliest = Number.MAX_SAFE_INTEGER
    let latest = 0
    for (const entry of entries) {
      if (entry.isDirectory || !DirectoryTimelinePolicy.isImage(entry)) {
        continue
      }
      timeline.directImageCount += 1
      const modifiedTime = DirectoryTimelinePolicy.timestampMs(entry.modifiedTime)
      if (modifiedTime <= 0) {
        continue
      }
      earliest = Math.min(earliest, modifiedTime)
      latest = Math.max(latest, modifiedTime)
      const dayStart = DirectoryTimelinePolicy.localDayStart(modifiedTime)
      buckets.set(dayStart, (buckets.get(dayStart) ?? 0) + 1)
    }
    timeline.earliestTime = earliest === Number.MAX_SAFE_INTEGER ? 0 : earliest
    timeline.latestTime = latest
    const days = Array.from(buckets.keys()).sort((left: number, right: number): number => left - right)
    timeline.buckets = days.map((dayStart: number): TimelineDayBucket => {
      const bucket = new TimelineDayBucket()
      bucket.dayStart = dayStart
      bucket.count = buckets.get(dayStart) ?? 0
      return bucket
    })
    return timeline
  }

  /**
   * Stable metadata fingerprint for deciding whether a refreshed snapshot can
   * leave the mounted LazyForEach untouched. It is independent of server page
   * order, so a different page arrival order does not look like a content
   * change to the UI. The aggregate is deliberately order-independent and
   * avoids sorting every metadata row on the UI thread when a background
   * refresh completes.
   */
  static contentSignature(entries: FileEntry[]): string {
    const modulus = 2147483647
    let first = 17
    let second = 31
    let count = 0
    for (const entry of entries) {
      const row = entry.path + '\u0001' + entry.name + '\u0001' +
        (entry.isDirectory ? '1' : '0') + '\u0001' + entry.size.toString() + '\u0001' +
        entry.modifiedTime.toString() + '\u0001' + entry.createdTime.toString() + '\u0001' +
        entry.childCount.toString() + '\u0001' + entry.etag + '\u0001' + entry.checksum
      let rowFirst = 7
      let rowSecond = 13
      for (let index = 0; index < row.length; index += 1) {
        const code = row.charCodeAt(index)
        rowFirst = (rowFirst * 31 + code) % modulus
        rowSecond = (rowSecond * 131 + code) % modulus
      }
      first = (first + rowFirst) % modulus
      second = (second + rowSecond) % modulus
      count += 1
    }
    return count.toString() + ':' + first.toString(16) + ':' + second.toString(16)
  }

  static query(entries: FileEntry[], query: DirectoryQuery): FileEntry[] {
    const filtered: FileEntry[] = []
    const from = query.dateFrom > 0 ? DirectoryTimelinePolicy.timestampMs(query.dateFrom) : 0
    const to = query.dateTo > 0 ? DirectoryTimelinePolicy.timestampMs(query.dateTo) : 0
    for (const entry of entries) {
      if (!DirectoryTimelinePolicy.matchesMediaFilter(entry, query.mediaFilter)) {
        continue
      }
      const modifiedTime = DirectoryTimelinePolicy.timestampMs(entry.modifiedTime)
      if (!entry.isDirectory) {
        if (from > 0 && modifiedTime < from) {
          continue
        }
        if (to > 0 && modifiedTime >= to) {
          continue
        }
      }
      filtered.push(entry)
    }
    return DirectoryTimelinePolicy.sort(filtered, query.sortKey, query.ascending)
  }

  static sort(entries: FileEntry[], sortKey: DirectorySortKey, ascending: boolean): FileEntry[] {
    const sorted = entries.slice()
    sorted.sort((left: FileEntry, right: FileEntry): number => {
      if (left.isDirectory !== right.isDirectory) {
        return left.isDirectory ? -1 : 1
      }
      let comparison = 0
      switch (sortKey) {
        case 'name':
          comparison = left.name.localeCompare(right.name)
          break
        case 'type':
          comparison = DirectoryTimelinePolicy.extension(left.name)
            .localeCompare(DirectoryTimelinePolicy.extension(right.name))
          break
        case 'size':
          comparison = left.size - right.size
          break
        case 'time':
        default:
          comparison = DirectoryTimelinePolicy.timestampMs(left.modifiedTime) -
            DirectoryTimelinePolicy.timestampMs(right.modifiedTime)
          break
      }
      if (comparison !== 0) {
        return ascending ? comparison : -comparison
      }
      const nameComparison = left.name.localeCompare(right.name)
      if (nameComparison !== 0) {
        return nameComparison
      }
      return left.path.localeCompare(right.path)
    })
    return sorted
  }

  static closestDay(timeline: DirectoryTimeline, targetTime: number): number {
    if (timeline.buckets.length === 0) {
      return 0
    }
    let low = 0
    let high = timeline.buckets.length
    while (low < high) {
      const middle = Math.floor((low + high) / 2)
      if (timeline.buckets[middle].dayStart < targetTime) {
        low = middle + 1
      } else {
        high = middle
      }
    }
    if (low <= 0) {
      return timeline.buckets[0].dayStart
    }
    if (low >= timeline.buckets.length) {
      return timeline.buckets[timeline.buckets.length - 1].dayStart
    }
    const before = timeline.buckets[low - 1].dayStart
    const after = timeline.buckets[low].dayStart
    return Math.abs(before - targetTime) <= Math.abs(after - targetTime) ? before : after
  }

  static dayInPeriod(timeline: DirectoryTimeline, targetTime: number,
    period: TimelinePeriod, ascending: boolean): number {
    let start = DirectoryTimelinePolicy.localDayStart(targetTime)
    let end = DirectoryTimelinePolicy.addLocalDays(start, 1)
    const date = new Date(targetTime)
    if (period === 'month') {
      start = new Date(date.getFullYear(), date.getMonth(), 1).getTime()
      end = new Date(date.getFullYear(), date.getMonth() + 1, 1).getTime()
    } else if (period === 'year') {
      start = new Date(date.getFullYear(), 0, 1).getTime()
      end = new Date(date.getFullYear() + 1, 0, 1).getTime()
    }
    let low = 0
    let high = timeline.buckets.length
    while (low < high) {
      const middle = Math.floor((low + high) / 2)
      if (timeline.buckets[middle].dayStart < start) {
        low = middle + 1
      } else {
        high = middle
      }
    }
    if (low < timeline.buckets.length && timeline.buckets[low].dayStart < end) {
      if (ascending) {
        return timeline.buckets[low].dayStart
      }
      let index = low
      while (index + 1 < timeline.buckets.length &&
        timeline.buckets[index + 1].dayStart < end) {
        index += 1
      }
      return timeline.buckets[index].dayStart
    }
    return DirectoryTimelinePolicy.closestDay(timeline, targetTime)
  }

  static localDayStart(value: number): number {
    const date = new Date(DirectoryTimelinePolicy.timestampMs(value))
    return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
  }

  private static addLocalDays(value: number, amount: number): number {
    const date = new Date(value)
    date.setDate(date.getDate() + amount)
    return date.getTime()
  }

  static timestampMs(value: number): number {
    return value > 0 && value < 100000000000 ? value * 1000 : value
  }

  static isImage(entry: FileEntry): boolean {
    const mime = entry.mimeType.toLowerCase()
    if (mime.startsWith('image/')) {
      return true
    }
    const extension = DirectoryTimelinePolicy.extension(entry.name)
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff']
      .indexOf(extension) >= 0
  }

  private static isVideo(entry: FileEntry): boolean {
    const mime = entry.mimeType.toLowerCase()
    if (mime.startsWith('video/')) {
      return true
    }
    const extension = DirectoryTimelinePolicy.extension(entry.name)
    return ['mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm', 'wmv', 'flv', 'ts', 'mts', 'm2ts',
      '3gp'].indexOf(extension) >= 0
  }

  private static matchesMediaFilter(entry: FileEntry, filter: DirectoryMediaFilter): boolean {
    if (filter === 'all' || entry.isDirectory) {
      return true
    }
    const image = DirectoryTimelinePolicy.isImage(entry)
    const video = DirectoryTimelinePolicy.isVideo(entry)
    if (filter === 'images') {
      return image
    }
    if (filter === 'videos') {
      return video
    }
    return image || video
  }

  private static extension(name: string): string {
    const index = name.lastIndexOf('.')
    return index >= 0 ? name.slice(index + 1).toLowerCase() : ''
  }
}

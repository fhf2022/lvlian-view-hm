import { FileEntry } from '../model/FileEntry'

export type AudioPlayMode = 'order' | 'repeat' | 'shuffle'

export class AudioLyricLine {
  timeMs: number = 0
  text: string = ''
}

export class AudioTrackInfo {
  title: string = ''
  artist: string = ''
  album: string = ''
}

export class AudioCoverRect {
  x: number = 0
  y: number = 0
  width: number = 0
  height: number = 0
  radius: number = 0
}

/** Project-owned playback UI policy. No online source, account or lyric engine dependencies. */
export class AudioPlayerPolicy {
  static title(name: string): string { return name.replace(/\.[^.]+$/, '') }

  static format(name: string): string {
    const extension = name.match(/\.([a-z0-9]{1,8})$/i)
    return extension === null ? 'AUDIO' : extension[1].toUpperCase()
  }

  static nextIndex(length: number, current: number, direction: number,
    mode: AudioPlayMode, completed: boolean = false, random: number = Math.random()): number {
    if (length <= 0 || current < 0 || current >= length) { return -1 }
    if (completed && mode === 'repeat') { return current }
    if (mode === 'shuffle' && length > 1) {
      const step = 1 + Math.floor(Math.max(0, Math.min(0.999999, random)) * (length - 1))
      return (current + step) % length
    }
    return (current + (direction < 0 ? -1 : 1) + length) % length
  }

  static lyricEntry(entry: FileEntry, entries: FileEntry[]): FileEntry | undefined {
    const stem = entry.path.replace(/\.[^/.]+$/, '').toLowerCase()
    return entries.find((item: FileEntry): boolean => !item.isDirectory &&
      item.size > 0 && item.size <= 256 * 1024 && item.path.toLowerCase() === stem + '.lrc')
  }

  static parseLyrics(text: string): AudioLyricLine[] {
    if (text.length > 256 * 1024) { return [] }
    const lines: AudioLyricLine[] = []
    const offsetMatch = text.match(/\[offset:([+-]?\d+)\]/i)
    const offset = offsetMatch === null ? 0 : Math.max(-3600000, Math.min(3600000, Number(offsetMatch[1])))
    for (const raw of text.split(/\r?\n/)) {
      const value = raw.replace(/\[\d+:\d+(?:\.\d+)?\]/g, '').trim()
      if (value.length === 0) { continue }
      const tags = raw.match(/\[\d+:\d+(?:\.\d+)?\]/g) ?? []
      for (const tag of tags) {
        const parts = tag.substring(1, tag.length - 1).split(':')
        const time = Number(parts[0]) * 60000 + Number(parts[1]) * 1000 + offset
        if (!Number.isFinite(time) || time > 7 * 24 * 3600000 || lines.length >= 3000) { continue }
        const line = new AudioLyricLine()
        line.timeMs = Math.max(0, Math.round(time)); line.text = value.substring(0, 2048)
        lines.push(line)
      }
    }
    return lines.sort((a: AudioLyricLine, b: AudioLyricLine): number => a.timeMs - b.timeMs)
  }

  static lyricIndex(lines: AudioLyricLine[], position: number): number {
    let low = 0
    let high = lines.length - 1
    let found = -1
    while (low <= high) {
      const mid = Math.floor((low + high) / 2)
      if (lines[mid].timeMs <= position) { found = mid; low = mid + 1 } else { high = mid - 1 }
    }
    return found
  }

  static returnTarget(rect: AudioCoverRect, visibleRatio: number,
    top: number, bottom: number, width: number): boolean {
    return [rect.x, rect.y, rect.width, rect.height].every((value: number): boolean => Number.isFinite(value)) &&
      visibleRatio >= 0.999 && rect.width > 0 && rect.height > 0 &&
      rect.x >= -1 && rect.x + rect.width <= width + 1 && rect.y >= top - 1 &&
      rect.y + rect.height <= bottom + 1
  }

  static thumbnailRect(rect: AudioCoverRect, artwork: boolean, iconSize: number): AudioCoverRect {
    const result = new AudioCoverRect()
    result.x = rect.x; result.y = rect.y; result.width = rect.width; result.height = rect.height
    result.radius = rect.radius
    if (!artwork) {
      const side = Math.min(iconSize, rect.width, rect.height)
      result.x += (rect.width - side) / 2; result.y += (rect.height - side) / 2
      result.width = side; result.height = side
    }
    return result
  }
}

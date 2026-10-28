import { FileEntry } from '../model/FileEntry'
import { DirectorySortKey } from '../model/DirectoryTimeline'

export type ContinuationScene = 'directory' | 'image' | 'audio' | 'video'
export type ContinuationView = 'list' | 'grid' | 'waterfall'

/** Versioned business state. Never contains credentials, media URLs or local cache paths. */
export class ContinuationState {
  protocol: number = 1
  requestId: string = ''
  createdAt: number = 0
  nasId: string = ''
  userId: string = ''
  scene: ContinuationScene = 'directory'
  rootKind: 'personal' | 'shared' = 'personal'
  path: string = ''
  rootType: number = 3
  view: ContinuationView = 'list'
  sort: DirectorySortKey = 'time'
  ascending: boolean = false
  anchor: string = ''
  // Optional so older peers can still exchange protocol 1/2 snapshots.
  anchorFraction?: number
  anchorAtStart?: boolean
  target: string = ''
  positionMs: number = 0
  playing: boolean = false
  count: number = 0
}

export class ContinuationSnapshot {
  state: ContinuationState = new ContinuationState()
  entries: FileEntry[] = []
}

/** One bounded JSONL row; thumbnails and raster data are obtained on the target. */
class ContinuationRow {
  n: string = ''
  p: string = ''
  d: boolean = false
  s: number = 0
  m: number = 0
  c: number = 0
  k: number = -1
  r: number = 3
  h: number = 0
  t: string = ''
  e: string = ''
  x: string = ''
}

export class ContinuationPolicy {
  static readonly MAX_ENTRIES: number = 50000
  static readonly MAX_BYTES: number = 16 * 1024 * 1024
  static readonly MAX_ROW_BYTES: number = 32768
  static readonly MAX_AGE_MS: number = 10 * 60 * 1000

  static text(value: string, limit: number): boolean {
    return typeof value === 'string' && value.length <= limit && !/[\u0000-\u001f]/.test(value)
  }

  static path(value: string, rootAllowed: boolean = false): boolean {
    if (value === '') { return rootAllowed }
    return ContinuationPolicy.text(value, 4096) && value.startsWith('/') && !value.endsWith('/') &&
      !value.includes('\\') && value.split('/').slice(1).every((part: string): boolean =>
        part.length > 0 && part !== '.' && part !== '..' && part !== '#recycle')
  }

  static directChild(parent: string, child: string): boolean {
    return ContinuationPolicy.path(child) && child.substring(0, child.lastIndexOf('/')) === parent
  }

  static listedChild(parent: string, child: string): boolean {
    return parent === '' ? ContinuationPolicy.path(child) : ContinuationPolicy.directChild(parent, child)
  }

  static integer(value: number, min: number = 0): boolean {
    return typeof value === 'number' && Number.isSafeInteger(value) && value >= min
  }

  static validate(state: ContinuationState): void {
    if (state === null || typeof state !== 'object' || ![1, 2].includes(state.protocol) ||
      typeof state.requestId !== 'string' || !/^[0-9a-f-]{36}$/.test(state.requestId) ||
      !ContinuationPolicy.integer(state.createdAt) || Math.abs(Date.now() - state.createdAt) > ContinuationPolicy.MAX_AGE_MS ||
      !ContinuationPolicy.text(state.nasId, 512) || state.nasId.length === 0 ||
      !ContinuationPolicy.text(state.userId, 512) || state.userId.length === 0 ||
      !['directory', 'image', 'audio', 'video'].includes(state.scene) ||
      (state.scene === 'audio' && state.protocol < 2) ||
      !['personal', 'shared'].includes(state.rootKind) || !ContinuationPolicy.path(state.path, true) ||
      ![2, 3, 4].includes(state.rootType) || !['list', 'grid', 'waterfall'].includes(state.view) ||
      !['name', 'type', 'time', 'size'].includes(state.sort) || typeof state.ascending !== 'boolean' ||
      typeof state.playing !== 'boolean' || !ContinuationPolicy.integer(state.positionMs) ||
      state.positionMs > 7 * 24 * 3600000 || !ContinuationPolicy.integer(state.count) || state.count > ContinuationPolicy.MAX_ENTRIES ||
      !ContinuationPolicy.text(state.anchor, 4096) || !ContinuationPolicy.text(state.target, 4096) ||
      (state.anchorFraction !== undefined && (typeof state.anchorFraction !== 'number' ||
        !Number.isFinite(state.anchorFraction) || state.anchorFraction < 0 || state.anchorFraction >= 1 ||
        typeof state.anchorAtStart !== 'boolean' || state.anchor.length === 0)) ||
      (state.anchorAtStart !== undefined && (typeof state.anchorAtStart !== 'boolean' || state.anchorFraction === undefined)) ||
      (state.anchor.length > 0 && !ContinuationPolicy.listedChild(state.path, state.anchor)) ||
      (state.scene !== 'directory' && !ContinuationPolicy.directChild(state.path, state.target)) ||
      (state.scene === 'directory' && state.target !== '')) {
      throw new Error('接续数据无效或已经过期')
    }
  }

  static encode(entry: FileEntry): string {
    const row = new ContinuationRow()
    row.n = entry.name; row.p = entry.path; row.d = entry.isDirectory; row.s = entry.size
    row.m = entry.modifiedTime; row.c = entry.createdTime; row.k = entry.childCount
    row.r = entry.rootType; row.h = entry.intranetShareId; row.t = entry.mimeType
    row.e = entry.etag; row.x = entry.checksum
    return JSON.stringify(row)
  }

  static decode(line: string, state: ContinuationState): FileEntry {
    if (line.length > ContinuationPolicy.MAX_ROW_BYTES) { throw new Error('接续条目过大') }
    const row = JSON.parse(line) as ContinuationRow
    if (row === null || typeof row !== 'object' || !ContinuationPolicy.text(row.n, 1024) || row.n.length === 0 ||
      !ContinuationPolicy.listedChild(state.path, row.p) ||
      (state.path === '' ? !row.d : row.n !== row.p.substring(row.p.lastIndexOf('/') + 1)) ||
      typeof row.d !== 'boolean' || !ContinuationPolicy.integer(row.s) || !ContinuationPolicy.integer(row.m) ||
      !ContinuationPolicy.integer(row.c) || !ContinuationPolicy.integer(row.k, -1) || ![0, 2, 3, 4].includes(row.r) ||
      !ContinuationPolicy.integer(row.h) || !ContinuationPolicy.text(row.t, 256) || !ContinuationPolicy.text(row.e, 1024) || !ContinuationPolicy.text(row.x, 1024)) {
      throw new Error('接续目录条目无效')
    }
    const entry = new FileEntry()
    entry.name = row.n; entry.path = row.p; entry.isDirectory = row.d; entry.size = row.s
    entry.modifiedTime = row.m; entry.createdTime = row.c; entry.childCount = row.k
    entry.rootType = row.r; entry.intranetShareId = row.h; entry.mimeType = row.t
    entry.etag = row.e; entry.checksum = row.x
    return entry
  }

  static sameAccount(state: ContinuationState, nasId: string, sessionIdentity: string): boolean {
    const separator = sessionIdentity.lastIndexOf('|')
    return separator > 0 && state.nasId === nasId.trim().toLowerCase() &&
      state.userId === sessionIdentity.substring(separator + 1)
  }

  /** Reconstruct only ancestors under a root the target account can actually see. */
  static ancestors(path: string, roots: FileEntry[]): string[] {
    if (path === '') { return [] }
    const root = roots.filter((entry: FileEntry): boolean => entry.isDirectory &&
      (path === entry.path || path.startsWith(entry.path + '/')))
      .sort((a: FileEntry, b: FileEntry): number => b.path.length - a.path.length)[0]
    if (root === undefined) { throw new Error('当前账号无法访问接续目录') }
    const result: string[] = ['']
    let current = root.path
    if (current === path) { return result }
    const parts = path.substring(current.length + 1).split('/')
    for (let i = 0; i < parts.length; i++) {
      result.push(current)
      current += '/' + parts[i]
    }
    return result
  }
}

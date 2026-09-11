import { Context } from '@kit.AbilityKit'
import { fileIo } from '@kit.CoreFileKit'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'

interface StorageFile {
  path: string
  size: number
  accessedAt: number
}

/** One process-wide budget. Admission and writes must have no await between them. */
export class StorageBudget {
  static readonly PERSISTENT_LIMIT: number = 512 * 1024 * 1024
  private static roots: string[] = []
  private static thumbnailRoot: string = ''
  private static metadataRoots: string[] = []
  private static limit: number = 1024 * 1024 * 1024
  private static pins: Map<string, number> = new Map<string, number>()
  private static files: Map<string, StorageFile> = new Map<string, StorageFile>()
  private static listeners: ((path: string) => void)[] = []
  private static protectedFiles: () => string[] = (): string[] => []
  private static pendingRemoval: Set<string> = new Set<string>()

  static removeWhenUnused(path: string): void {
    if (!StorageBudget.isTemporary(path)) { return }
    StorageBudget.pendingRemoval.add(path)
    StorageBudget.drainRemoval(path)
  }
  private static drainRemoval(path: string): void {
    if (!StorageBudget.pendingRemoval.has(path) || StorageBudget.pins.has(path) ||
      StorageBudget.protectedFiles().indexOf(path) >= 0) { return }
    try { fileIo.unlinkSync(path); StorageBudget.pendingRemoval.delete(path) } catch (_) {}
    StorageBudget.sync(path)
  }

  static initialize(context: Context, limit: number): void {
    StorageBudget.roots = [context.cacheDir, context.tempDir,
      context.filesDir + '/ugreen-download-tasks', context.filesDir + '/ugreen-video-transfers',
      context.filesDir + '/ugreen-upload-tasks']
    StorageBudget.thumbnailRoot = context.filesDir + '/ugreen-thumbnail-cache'
    StorageBudget.metadataRoots = [context.databaseDir, context.preferencesDir,
      context.filesDir + '/ugreen-thumbnail-index.json']
    StorageBudget.limit = limit
    StorageBudget.scan()
  }

  static protect(provider: () => string[]): void { StorageBudget.protectedFiles = provider }
  static onEvicted(listener: (path: string) => void): void { StorageBudget.listeners.push(listener) }
  static isTemporary(path: string): boolean {
    return StorageBudget.roots.some((root: string): boolean => path.startsWith(root + '/'))
  }
  static pin(path: string): void {
    StorageBudget.pins.set(path, (StorageBudget.pins.get(path) || 0) + 1)
    StorageBudget.touch(path)
  }
  static unpin(path: string): void {
    const count = StorageBudget.pins.get(path) || 0
    if (count <= 1) { StorageBudget.pins.delete(path) } else { StorageBudget.pins.set(path, count - 1) }
    StorageBudget.sync(path)
    StorageBudget.drainRemoval(path)
  }
  static touch(path: string): void {
    StorageBudget.sync(path)
    const item = StorageBudget.files.get(path)
    if (item !== undefined) { item.accessedAt = Date.now() }
    try { fileIo.utimes(path, Date.now()) } catch (_) {}
  }
  static sync(path: string): void {
    if (!StorageBudget.isTemporary(path)) { return }
    try {
      const stat = fileIo.statSync(path)
      const previous = StorageBudget.files.get(path)
      if (stat.isFile()) {
        StorageBudget.files.set(path, { path: path, size: stat.size,
          accessedAt: previous === undefined ? stat.mtime * 1000 : previous.accessedAt })
      }
    } catch (_) { StorageBudget.files.delete(path) }
  }
  static scan(): number {
    const previous = StorageBudget.files
    StorageBudget.files = new Map<string, StorageFile>()
    for (const root of StorageBudget.roots) {
      for (const item of StorageBudget.walk(root)) {
        const old = previous.get(item.path)
        if (old !== undefined) { item.accessedAt = old.accessedAt }
        StorageBudget.files.set(item.path, item)
      }
    }
    return StorageBudget.usage()
  }
  static usage(): number {
    let total = 0
    StorageBudget.files.forEach((item: StorageFile): void => { total += item.size })
    return total
  }
  static setLimit(value: number): void {
    const previous = StorageBudget.limit
    StorageBudget.limit = value
    StorageBudget.scan()
    try { StorageBudget.admit('', 0) } catch (error) {
      StorageBudget.limit = previous
      throw error as Error
    }
  }
  static admit(path: string, resultingSize: number): void {
    if (path.length > 0 && !StorageBudget.isTemporary(path)) { return }
    StorageBudget.sync(path)
    const old = StorageBudget.files.get(path)
    const growth = Math.max(0, resultingSize - (old === undefined ? 0 : old.size))
    let projected = StorageBudget.usage() + growth
    const protectedPaths = StorageBudget.protectedFiles()
    const candidates = Array.from(StorageBudget.files.values()).sort(
      (a: StorageFile, b: StorageFile): number => a.accessedAt - b.accessedAt)
    for (const item of candidates) {
      if (projected <= StorageBudget.limit) { break }
      if (item.path === path || StorageBudget.pins.has(item.path) || protectedPaths.indexOf(item.path) >= 0) { continue }
      if (StorageBudget.evict(item.path)) { projected -= item.size }
    }
    if (projected > StorageBudget.limit) {
      throw new UgreenError(UgreenErrorKind.UNKNOWN, '临时缓存空间不足，请提高缓存上限或移除未完成下载')
    }
  }
  static clearDisposable(): void {
    StorageBudget.scan()
    const protectedPaths = StorageBudget.protectedFiles()
    for (const item of Array.from(StorageBudget.files.values())) {
      // Task removal owns resumable partials; automatic pressure may evict them.
      if (item.path.endsWith('.part') || StorageBudget.pins.has(item.path) ||
        protectedPaths.indexOf(item.path) >= 0) { continue }
      StorageBudget.evict(item.path)
    }
  }
  private static evict(path: string): boolean {
    try { fileIo.unlinkSync(path) } catch (_) { return false }
    StorageBudget.files.delete(path)
    for (const listener of StorageBudget.listeners) {
      try { listener(path) } catch (error) { console.warn('[StorageBudget] ' + String(error)) }
    }
    return true
  }
  static metadataUsage(): number {
    let bytes = 0
    for (const root of StorageBudget.metadataRoots) {
      for (const item of StorageBudget.walk(root)) { bytes += item.size }
    }
    return bytes
  }
  static persistentUsage(): number {
    return StorageBudget.metadataUsage() + StorageBudget.walk(StorageBudget.thumbnailRoot).reduce(
      (sum: number, item: StorageFile): number => sum + item.size, 0)
  }
  static thumbnailAllowance(): number {
    return Math.max(1, StorageBudget.PERSISTENT_LIMIT - StorageBudget.metadataUsage())
  }
  private static walk(path: string): StorageFile[] {
    if (path.length === 0) { return [] }
    try {
      const stat = fileIo.statSync(path)
      if (stat.isFile()) { return [{ path: path, size: stat.size, accessedAt: stat.mtime * 1000 }] }
      if (!stat.isDirectory()) { return [] }
      const result: StorageFile[] = []
      for (const name of fileIo.listFileSync(path)) {
        result.push(...StorageBudget.walk(path + '/' + name))
      }
      return result
    } catch (_) { return [] }
  }
}

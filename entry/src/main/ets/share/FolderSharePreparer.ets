import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { FileEntry } from '../model/FileEntry'
import { DownloadDestination } from '../download/DownloadDestination'
import { StorageBudget } from '../download/StorageBudget'

export interface FolderSharePage { entries: FileEntry[]; hasMore: boolean }
export type ShareFileMaterializer = (entry: FileEntry, sourcePath: string) => Promise<string>
export interface FolderShareSource {
  list: (entry: FileEntry, page: number) => Promise<FolderSharePage>
  cache: (entries: FileEntry[], pins: string[], valid: () => boolean,
    materialize: ShareFileMaterializer) => Promise<Record<string, string>>
  valid: () => boolean
}
export interface PreparedShareFolder { path: string; uri: string }
interface FolderItem { entry: FileEntry; relative: string; depth: number }
interface StagedFile { relative: string; size: number }
interface ShareManifest {
  id: string
  baseUri: string
  directories: string[]
  files: StagedFile[]
  complete: boolean
  expiresAt: number
}
interface FolderSnapshot { version: string; manifest: ShareManifest; results: Record<string, PreparedShareFolder> }

/** One directory materializer for menu, multi-selection and gesture sharing. */
export class FolderSharePreparer {
  private static readonly SUBDIRECTORY: string = '/temp/.linkfiles-folder-share-v1'
  private static readonly RETENTION_MS: number = 24 * 60 * 60 * 1000
  private static readonly MAX_ITEMS: number = 10000
  private static active: Set<string> = new Set<string>()
  private directory: string = ''
  private initializing: Promise<void> | null = null
  private jobs: Map<string, ShareManifest> = new Map<string, ShareManifest>()
  private ready: Map<string, FolderSnapshot> = new Map<string, FolderSnapshot>()

  initialize(context: Context): Promise<void> {
    if (this.initializing === null) {
      this.directory = context.filesDir + '/ugreen-folder-shares'
      this.initializing = this.restore().catch((error: Error): void => {
        this.initializing = null
        throw error
      })
    }
    return this.initializing
  }

  private async restore(): Promise<void> {
    if (!fileIo.accessSync(this.directory)) { await fileIo.mkdir(this.directory, true) }
    for (const name of await fileIo.listFile(this.directory)) {
      if (!/^[a-f0-9-]{36}\.json$/.test(name)) { continue }
      try {
        const manifest = JSON.parse(await fileIo.readText(this.directory + '/' + name)) as ShareManifest
        if (!this.validManifest(manifest) || name !== manifest.id + '.json') { continue }
        this.jobs.set(manifest.id, manifest)
        const root = this.jobRoot(manifest)
        for (const item of manifest.files) {
          StorageBudget.registerSharedTemporary(root + '/' + item.relative, item.size,
            manifest.complete ? manifest.expiresAt : 0)
        }
      } catch (error) { console.warn('[FolderShare] manifest ignored: ' + String(error)) }
    }
    // Refresh DOWNLOAD's process grant only for installations that already used folder sharing.
    // No public-tree scan or original-image work is added to ordinary startup/scrolling.
    if (this.jobs.size > 0) {
      try { await DownloadDestination.directoryUri() }
      catch (error) { console.warn('[FolderShare] directory grant deferred: ' + String(error)) }
    }
  }

  /** Used on explicit cache maintenance and before a new export, never while scrolling. */
  async sweep(): Promise<void> {
    if (!Array.from(this.jobs.values()).some((job: ShareManifest): boolean =>
      !FolderSharePreparer.active.has(job.id) && (!job.complete || job.expiresAt <= Date.now()))) { return }
    await DownloadDestination.directoryUri()
    for (const manifest of Array.from(this.jobs.values())) {
      if (!FolderSharePreparer.active.has(manifest.id) &&
        (!manifest.complete || manifest.expiresAt <= Date.now())) { await this.remove(manifest) }
    }
  }

  async prepare(entry: FileEntry, scope: string, source: FolderShareSource,
    pins: string[]): Promise<PreparedShareFolder> {
    return (await this.prepareSelection([entry], scope, source, pins))[entry.path]
  }

  async prepareSelection(entries: FileEntry[], scope: string, source: FolderShareSource,
    pins: string[]): Promise<Record<string, PreparedShareFolder>> {
    if (this.initializing === null) { throw new Error('分享缓存尚未初始化') }
    await this.initializing
    await this.sweep()
    this.check(source)
    const directories: FolderItem[] = []
    const files: FolderItem[] = []
    const seen: Set<string> = new Set<string>()
    const names: Set<string> = new Set<string>()
    for (const entry of entries) {
      this.checkName(entry.name)
      if (seen.has(entry.path) || names.has(entry.name.toLowerCase())) {
        throw new Error('所选项目包含本机同名文件，请分开分享')
      }
      seen.add(entry.path); names.add(entry.name.toLowerCase())
      const item: FolderItem = { entry: entry, relative: entry.name, depth: 0 }
      if (entry.isDirectory) { directories.push(item) } else { files.push(item) }
    }
    for (let index = 0; index < directories.length; index += 1) {
      const parent = directories[index]
      for (let pageIndex = 1; ; pageIndex += 1) {
        this.check(source)
        if (pageIndex > 1000) { throw new Error('文件夹项目过多，请分批分享') }
        const page = await source.list(parent.entry, pageIndex)
        this.check(source)
        if (page.hasMore && page.entries.length === 0) { throw new Error('文件夹列表不完整，请重试') }
        for (const child of page.entries) {
          this.checkName(child.name)
          if (child.path !== parent.entry.path.replace(/\/+$/, '') + '/' + child.name || seen.has(child.path)) {
            throw new Error('文件夹路径异常，已停止分享')
          }
          seen.add(child.path)
          if (seen.size > FolderSharePreparer.MAX_ITEMS || parent.depth >= 64) {
            throw new Error('文件夹项目过多或层级过深，请分批分享')
          }
          const item: FolderItem = { entry: child, relative: parent.relative + '/' + child.name,
            depth: parent.depth + 1 }
          if (names.has(item.relative.toLowerCase())) { throw new Error('文件夹包含本机同名项目，请分开分享') }
          names.add(item.relative.toLowerCase())
          if (child.isDirectory) { directories.push(item) } else { files.push(item) }
        }
        if (!page.hasMore) { break }
      }
    }
    if (files.length === 0) { throw new Error('文件夹没有可分享的文件') }
    const key = scope + ':' + entries.map((entry: FileEntry): string =>
      entry.rootType.toString() + ':' + entry.path).sort().join('\n')
    const version = directories.concat(files).map((item: FolderItem): string => {
      const value = item.entry
      return JSON.stringify([item.relative, value.size.toString(), value.modifiedTime.toString(), value.etag, value.checksum])
    }).sort().join('\n')
    const previous = this.ready.get(key)
    if (previous !== undefined && previous.version === version &&
      previous.manifest.expiresAt > Date.now() && await this.intact(previous.manifest)) {
      this.check(source)
      return previous.results
    }
    this.ready.delete(key)
    let retained = 0
    this.jobs.forEach((job: ShareManifest): void => { retained += job.files.length + job.directories.length })
    if (retained + seen.size > FolderSharePreparer.MAX_ITEMS) {
      throw new Error('正在保留的分享项目较多，请稍后重试')
    }
    const baseUri = await DownloadDestination.directoryUri()
    const manifest: ShareManifest = {
      id: util.generateRandomUUID(false), baseUri: baseUri,
      directories: directories.map((item: FolderItem): string => item.relative),
      files: files.map((item: FolderItem): StagedFile => ({ relative: item.relative, size: Math.max(0, item.entry.size) })),
      complete: false, expiresAt: 0
    }
    if (!this.validManifest(manifest)) { throw new Error('系统下载目录不支持文件夹分享') }
    this.check(source)
    // Persist the owned paths before any public writes. A restart can clean an interrupted job.
    await this.persist(manifest)
    this.jobs.set(manifest.id, manifest)
    FolderSharePreparer.active.add(manifest.id)
    const root = this.jobRoot(manifest)
    const items: Map<string, number> = new Map<string, number>()
    files.forEach((item: FolderItem, index: number): void => { items.set(item.entry.path, index) })
    const ownedOutput: string[] = []
    try {
      await fileIo.mkdir(root, true)
      for (const item of manifest.directories) { this.check(source); await fileIo.mkdir(root + '/' + item, true) }
      const materialize: ShareFileMaterializer = async (file: FileEntry, local: string): Promise<string> => {
        this.check(source)
        const index = items.get(file.path)
        if (index === undefined) { throw new Error('分享文件不在当前目录清单中') }
        const item = manifest.files[index]
        const stat = await fileIo.stat(local)
        if (!stat.isFile()) { throw new Error('原文件缓存已失效') }
        const path = root + '/' + item.relative
        StorageBudget.registerSharedTemporary(path, 0)
        StorageBudget.pin(path); pins.push(path); ownedOutput.push(path)
        StorageBudget.admit(path, stat.size)
        if (fileIo.accessSync(path)) { throw new Error('分享暂存目录存在同名项目，请分开分享') }
        const target = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE)
        try {
          // Admission, reservation and accounting precede the asynchronous native copy.
          fileIo.truncateSync(target.fd, stat.size)
          StorageBudget.sync(path)
          await fileIo.copyFile(local, target.fd)
        } finally { fileIo.closeSync(target) }
        StorageBudget.sync(path)
        this.check(source)
        if ((await fileIo.stat(path)).size !== stat.size) { throw new Error('分享文件复制不完整') }
        item.size = stat.size
        // The common cache worker owns this source pin. Once copied, later workers may reclaim it.
        const sourcePin = pins.indexOf(local)
        if (sourcePin >= 0) { pins.splice(sourcePin, 1); StorageBudget.unpin(local) }
        return path
      }
      const cached = await source.cache(files.map((item: FolderItem): FileEntry => item.entry), pins,
        source.valid, materialize)
      this.check(source)
      if (files.some((item: FolderItem): boolean => !cached[item.entry.path])) {
        throw new Error('文件夹内有文件未准备完成，请检查网络与缓存空间')
      }
      manifest.complete = true
      // share() acknowledges handover, not the end of transmission. Do not delete on its return.
      manifest.expiresAt = Date.now() + FolderSharePreparer.RETENTION_MS
      await this.persist(manifest)
      this.check(source)
      for (const item of manifest.files) {
        StorageBudget.registerSharedTemporary(root + '/' + item.relative, item.size, manifest.expiresAt)
      }
      const results: Record<string, PreparedShareFolder> = {}
      for (const entry of entries) {
        results[entry.path] = { path: root + '/' + entry.name,
          uri: baseUri + FolderSharePreparer.SUBDIRECTORY + '/' + manifest.id + '/' + encodeURIComponent(entry.name) }
      }
      this.ready.set(key, { version: version, manifest: manifest, results: results })
      return results
    } catch (error) {
      manifest.complete = false
      for (const path of ownedOutput) {
        const index = pins.indexOf(path)
        if (index >= 0) { pins.splice(index, 1); StorageBudget.unpin(path) }
      }
      await this.remove(manifest)
      throw error as Error
    } finally { FolderSharePreparer.active.delete(manifest.id) }
  }

  private check(source: FolderShareSource): void {
    if (!source.valid()) { throw new Error('账号或当前页面已变化，已停止准备分享') }
  }
  private checkName(name: string): void {
    if (!name || name === '.' || name === '..' || /[\/\\\u0000]/.test(name)) { throw new Error('文件夹包含无效名称') }
  }
  private jobRoot(manifest: ShareManifest): string {
    return new fileUri.FileUri(manifest.baseUri).path.replace(/\/+$/, '') +
      FolderSharePreparer.SUBDIRECTORY + '/' + manifest.id
  }
  private validManifest(manifest: ShareManifest): boolean {
    try {
      const path = new fileUri.FileUri(manifest.baseUri).path
      if (!manifest.baseUri.startsWith('file://docs/') || !path.startsWith('/storage/Users/') ||
        !path.endsWith('/Download/cn.fhf.linkfiles') || path.split('/').indexOf('..') >= 0 ||
        !/^[a-f0-9-]{36}$/.test(manifest.id) || !Array.isArray(manifest.files) ||
        !Array.isArray(manifest.directories) || manifest.files.length + manifest.directories.length > FolderSharePreparer.MAX_ITEMS ||
        !Number.isFinite(manifest.expiresAt) || manifest.expiresAt < 0 || typeof manifest.complete !== 'boolean') { return false }
      for (const relative of manifest.directories.concat(manifest.files.map((item: StagedFile): string => item.relative))) {
        for (const name of relative.split('/')) { this.checkName(name) }
      }
      return manifest.files.every((item: StagedFile): boolean => Number.isFinite(item.size) && item.size >= 0)
    } catch (_) { return false }
  }
  private async persist(manifest: ShareManifest): Promise<void> {
    const path = this.directory + '/' + manifest.id + '.json'
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(manifest))
    const file = await fileIo.open(path + '.pending', fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC)
    try {
      let offset = 0
      while (offset < bytes.byteLength) {
        const count = await fileIo.write(file.fd, bytes.buffer.slice(offset) as ArrayBuffer)
        if (count <= 0) { throw new Error('无法保存分享准备记录') }
        offset += count
      }
    } finally { fileIo.closeSync(file) }
    await fileIo.rename(path + '.pending', path)
  }
  private async intact(manifest: ShareManifest): Promise<boolean> {
    const root = this.jobRoot(manifest)
    try {
      for (const item of manifest.files) {
        const stat = await fileIo.stat(root + '/' + item.relative)
        if (!stat.isFile() || stat.size !== item.size) { return false }
      }
      return true
    } catch (_) { return false }
  }
  private async remove(manifest: ShareManifest): Promise<void> {
    if (!this.validManifest(manifest)) { return }
    const root = this.jobRoot(manifest)
    let retained = false
    for (const item of manifest.files) {
      const path = root + '/' + item.relative
      try { await fileIo.unlink(path); StorageBudget.forgetSharedTemporary(path) }
      catch (_) {
        try { await fileIo.stat(path); retained = true }
        catch (_) { StorageBudget.forgetSharedTemporary(path) }
      }
    }
    if (retained) { return }
    // Only owned, now-empty directories. Preserve anything added by the user.
    for (const path of manifest.directories.slice().sort((a: string, b: string): number => b.length - a.length)
      .map((relative: string): string => root + '/' + relative).concat([root])) {
      try { if ((await fileIo.listFile(path)).length === 0) { await fileIo.rmdir(path) } } catch (_) {}
    }
    try {
      await fileIo.unlink(this.directory + '/' + manifest.id + '.json')
      this.jobs.delete(manifest.id)
      this.ready.forEach((snapshot: FolderSnapshot, key: string): void => {
        if (snapshot.manifest.id === manifest.id) { this.ready.delete(key) }
      })
    } catch (_) {}
  }
}

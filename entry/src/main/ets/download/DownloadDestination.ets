import { Context } from '@kit.AbilityKit'
import { fileIo, fileUri, picker } from '@kit.CoreFileKit'
import { preferences } from '@kit.ArkData'
import { StorageBudget } from './StorageBudget'
import { TransferBackgroundManager } from '../transfer/TransferBackgroundManager'

interface SaveIntent {
  source: string
  target: string
  size: number
  committed: boolean
  acknowledged?: boolean
}

/** Public user files are obtained from the system's DOWNLOAD grant, never filesDir. */
export class DownloadDestination {
  private static context: Context | null = null
  private static queue: Promise<void> = Promise.resolve()
  private static grantedRoot: string = ''
  private static granting: Promise<string> | null = null

  private static recoveryStarted: boolean = false
  static initialize(context: Context): void {
    DownloadDestination.context = context
    if (!DownloadDestination.recoveryStarted) {
      DownloadDestination.recoveryStarted = true
      DownloadDestination.queue = DownloadDestination.recover().catch((error: Object): void => {
        console.warn('[DownloadDestination] recovery deferred: ' + String(error))
      })
    }
  }

  private static async recover(): Promise<void> {
    if (DownloadDestination.context === null) { return }
    const store = await preferences.getPreferences(DownloadDestination.context, 'ugreen-save-transactions')
    const values = await store.getAll()
    const keys = Object.keys(values)
    if (keys.length === 0) { return }
    const root = await DownloadDestination.directory()
    for (const key of keys) {
      try {
        const raw = await store.get(key, '')
        if (typeof raw !== 'string') { continue }
        const intent = JSON.parse(raw) as SaveIntent
        if (intent.source !== key || !StorageBudget.isTemporary(key) ||
          !intent.target.startsWith(root + '/') || intent.target.split('/').indexOf('..') >= 0) { continue }
        if (!intent.committed) {
          if (DownloadDestination.exists(intent.target)) { fileIo.unlinkSync(intent.target) }
          await store.delete(key)
        } else if (intent.acknowledged) {
          StorageBudget.removeWhenUnused(key)
          if (!DownloadDestination.exists(key)) { await store.delete(key) }
        }
      } catch (error) { console.warn('[DownloadDestination] transaction retained: ' + String(error)) }
    }
    await store.flush()
  }

  static async directory(): Promise<string> {
    if (DownloadDestination.grantedRoot) { return DownloadDestination.grantedRoot }
    if (DownloadDestination.granting) { return await DownloadDestination.granting }
    if (!TransferBackgroundManager.shared().isForeground()) { throw new Error('请回到前台授权下载保存目录') }
    DownloadDestination.granting = DownloadDestination.obtainDirectory()
    try {
      DownloadDestination.grantedRoot = await DownloadDestination.granting
      return DownloadDestination.grantedRoot
    } finally { DownloadDestination.granting = null }
  }

  private static async obtainDirectory(): Promise<string> {
    if (DownloadDestination.context === null) { throw new Error('下载目录尚未初始化') }
    const options = new picker.DocumentSaveOptions()
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD
    const result = await new picker.DocumentViewPicker(DownloadDestination.context).save(options)
    if (result.length === 0) { throw new Error('无法获取系统下载目录') }
    return new fileUri.FileUri(result[0]).path.replace(/\/+$/, '')
  }

  static async save(source: string, relativePath: string, shouldContinue?: () => boolean): Promise<string> {
    StorageBudget.pin(source)
    let finalPath = ''
    const operation = DownloadDestination.queue.then(async (): Promise<void> => {
      finalPath = await DownloadDestination.publish(source, relativePath, shouldContinue)
    })
    DownloadDestination.queue = operation.catch((): void => {})
    try { await operation; return finalPath } finally { StorageBudget.unpin(source) }
  }

  private static async publish(source: string, relativePath: string, shouldContinue?: () => boolean): Promise<string> {
    if (DownloadDestination.context === null) { throw new Error('下载目录尚未初始化') }
    StorageBudget.pin(source)
    try {
      const root = await DownloadDestination.directory()
      const store = await preferences.getPreferences(DownloadDestination.context, 'ugreen-save-transactions')
      const saved = await store.get(source, '')
      if (shouldContinue !== undefined && !shouldContinue()) { throw new Error('保存已取消') }
      let intent: SaveIntent | null = null
      if (typeof saved === 'string' && saved.length > 0) {
        intent = JSON.parse(saved) as SaveIntent
        if (!intent.target.startsWith(root + '/')) { throw new Error('保存目录已改变，请重试') }
        if (intent.committed || !DownloadDestination.exists(source)) {
          if (DownloadDestination.exists(intent.target) && fileIo.statSync(intent.target).size === intent.size) {
            return intent.target
          }
          throw new Error('已保存文件被移动或删除')
        }
        // Interrupted copy: only remove the exact destination owned by this intent.
        if (DownloadDestination.exists(intent.target)) { fileIo.unlinkSync(intent.target) }
      }
      const size = fileIo.statSync(source).size
      if (intent === null) {
        const relative = DownloadDestination.safeRelativePath(relativePath)
        const slash = relative.lastIndexOf('/')
        const directory = slash < 0 ? root : root + '/' + relative.substring(0, slash)
        const name = relative.substring(slash + 1)
        if (!DownloadDestination.exists(directory)) { fileIo.mkdirSync(directory, true) }
        intent = { source: source, target: DownloadDestination.uniquePath(directory, name), size: size, committed: false }
        await store.put(source, JSON.stringify(intent))
        await store.flush()
      }
      try {
        if (shouldContinue !== undefined && !shouldContinue()) { throw new Error('保存已取消') }
        // Copy preserves readers and the only resumable source if finalization fails.
        await fileIo.copyFile(source, intent.target)
        if (shouldContinue !== undefined && !shouldContinue()) { throw new Error('保存已取消') }
        if (fileIo.statSync(intent.target).size !== size) { throw new Error('保存文件校验失败') }
        intent.committed = true
        await store.put(source, JSON.stringify(intent))
        await store.flush()
        return intent.target
      } catch (error) {
        intent.committed = false
        try {
          await store.put(source, JSON.stringify(intent))
          await store.flush()
        } catch (journalError) { console.warn('[DownloadDestination] rollback journal: ' + String(journalError)) }
        if (DownloadDestination.exists(intent.target)) { fileIo.unlinkSync(intent.target) }
        throw error as Error
      }
    } finally { StorageBudget.unpin(source) }
  }

  /** Call only after the owning task/index has durably recorded the public path. */
  static async acknowledge(source: string): Promise<void> {
    if (DownloadDestination.context === null) { return }
    // Cleanup must never turn a durably saved user file back into a failed task.
    try {
      const store = await preferences.getPreferences(DownloadDestination.context, 'ugreen-save-transactions')
      const raw = await store.get(source, '')
      if (typeof raw === 'string' && raw.length > 0) {
        const intent = JSON.parse(raw) as SaveIntent
        intent.acknowledged = true
        await store.put(source, JSON.stringify(intent))
        await store.flush()
      }
      StorageBudget.removeWhenUnused(source)
      if (!DownloadDestination.exists(source)) {
        await store.delete(source)
        await store.flush()
      }
    } catch (error) { console.warn('[DownloadDestination] cleanup deferred: ' + String(error)) }
  }

  static safeRelativePath(path: string): string {
    const parts = path.split(/[\\/]+/)
    if (parts.some((part: string): boolean => part === '..')) { throw new Error('无效的保存路径') }
    const safe = parts.filter((part: string): boolean => part.length > 0 && part !== '.').map(
      (part: string): string => part.replace(/[\\/:*?"<>|]/g, '_'))
    if (safe.length === 0) { throw new Error('文件名不能为空') }
    return safe.join('/')
  }
  private static exists(path: string): boolean {
    try { fileIo.statSync(path); return true } catch (_) { return false }
  }
  private static uniquePath(directory: string, name: string): string {
    let path = directory + '/' + name
    let suffix = 1
    const dot = name.lastIndexOf('.')
    const stem = dot > 0 ? name.substring(0, dot) : name
    const extension = dot > 0 ? name.substring(dot) : ''
    while (DownloadDestination.exists(path)) { path = directory + '/' + stem + ' (' + (suffix++).toString() + ')' + extension }
    return path
  }
}

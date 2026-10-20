import { common } from '@kit.AbilityKit'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { commonType } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { ContinuationPolicy, ContinuationSnapshot, ContinuationState } from './ContinuationModel'

export class ContinuationSnapshotStore {
  static fileName(id: string): string { return 'linkfiles-continuation-' + id + '.jsonl' }

  static async remove(path: string): Promise<void> {
    try { await fileIo.unlink(path) } catch (_) {}
  }

  static async prune(context: common.UIAbilityContext): Promise<void> {
    // A process may be killed before its expiry timer runs. Only remove our
    // own expired regular files; never traverse arbitrary transferred paths.
    try {
      const names = await fileIo.listFile(context.distributedFilesDir)
      for (const name of names) {
        if (!/^linkfiles-continuation-[0-9a-f-]{36}\.jsonl$/.test(name)) { continue }
        const path = context.distributedFilesDir + '/' + name
        try {
          const stat = await fileIo.stat(path)
          if (stat.isFile() && Date.now() - stat.mtime * 1000 > ContinuationPolicy.MAX_AGE_MS) {
            await ContinuationSnapshotStore.remove(path)
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /** Yield between batches; never stringify an entire large gallery on the UI thread. */
  static async write(context: common.UIAbilityContext, snapshot: ContinuationSnapshot,
    valid: () => boolean): Promise<commonType.Asset> {
    const state = snapshot.state
    ContinuationPolicy.validate(state)
    if (snapshot.entries.length !== state.count) { throw new Error('接续目录不完整') }
    const name = ContinuationSnapshotStore.fileName(state.requestId)
    const path = context.distributedFilesDir + '/' + name
    const file = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
      fileIo.OpenMode.TRUNC)
    let size = 0
    const encoder = new util.TextEncoder()
    try {
      for (let start = 0; start < snapshot.entries.length || start === 0; start += 200) {
        if (!valid()) { throw new Error('接续已取消') }
        const lines: string[] = []
        if (start === 0) { lines.push(JSON.stringify(state)) }
        const end = Math.min(start + 200, snapshot.entries.length)
        for (let index = start; index < end; index++) {
          const line = ContinuationPolicy.encode(snapshot.entries[index])
          // Apply the same validation before export as on receipt.
          ContinuationPolicy.decode(line, state)
          lines.push(line)
        }
        const bytes = encoder.encodeInto(lines.join('\n') + '\n')
        size += bytes.byteLength
        if (size > ContinuationPolicy.MAX_BYTES) { throw new Error('目录过大，暂不支持接续') }
        let written = 0
        while (written < bytes.byteLength) {
          const remaining = bytes.buffer.slice(bytes.byteOffset + written, bytes.byteOffset + bytes.byteLength)
          const count = await fileIo.write(file.fd, remaining)
          if (count <= 0) { throw new Error('无法写入接续快照') }
          written += count
        }
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0) })
      }
    } catch (error) {
      await fileIo.close(file)
      await ContinuationSnapshotStore.remove(path)
      throw error as Error
    }
    await fileIo.close(file)
    if (!valid()) {
      await ContinuationSnapshotStore.remove(path)
      throw new Error('接续已取消')
    }
    const stat = await fileIo.stat(path)
    return { name: name, uri: fileUri.getUriFromPath(path), path: path,
      createTime: stat.ctime.toString(), modifyTime: stat.mtime.toString(), size: stat.size.toString() }
  }

  static async read(context: common.UIAbilityContext, id: string, asset: commonType.Asset,
    valid: () => boolean): Promise<ContinuationSnapshot> {
    // Ignore the source's sandbox path/URI. The transferred asset belongs in our distributed directory.
    if (asset === null || asset === undefined || asset.name !== ContinuationSnapshotStore.fileName(id)) {
      throw new Error('接续文件无效')
    }
    const path = context.distributedFilesDir + '/' + ContinuationSnapshotStore.fileName(id)
    const stat = await fileIo.stat(path)
    if (!stat.isFile() || stat.size <= 0 || stat.size > ContinuationPolicy.MAX_BYTES ||
      stat.size.toString() !== asset.size) { throw new Error('接续文件大小无效') }
    const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY)
    const snapshot = new ContinuationSnapshot()
    const paths = new Set<string>()
    const decoder = util.TextDecoder.create('utf-8', { fatal: true })
    let pending = ''
    let header = false
    let consumed = 0
    try {
      while (consumed < stat.size) {
        if (!valid()) { throw new Error('接续已取消') }
        const buffer = new ArrayBuffer(Math.min(32768, stat.size - consumed))
        const count = await fileIo.read(file.fd, buffer)
        if (count <= 0) { throw new Error('接续文件不完整') }
        consumed += count
        pending += decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: consumed < stat.size })
        let newline = pending.indexOf('\n')
        while (newline >= 0) {
          const line = pending.substring(0, newline)
          pending = pending.substring(newline + 1)
          if (line.length === 0) { throw new Error('接续文件格式无效') }
          if (!header) {
            snapshot.state = JSON.parse(line) as ContinuationState
            ContinuationPolicy.validate(snapshot.state)
            if (snapshot.state.requestId !== id) { throw new Error('接续会话不匹配') }
            header = true
          } else {
            const entry = ContinuationPolicy.decode(line, snapshot.state)
            if (paths.has(entry.path) || snapshot.entries.length >= snapshot.state.count) {
              throw new Error('接续条目重复或数量无效')
            }
            paths.add(entry.path)
            snapshot.entries.push(entry)
          }
          newline = pending.indexOf('\n')
        }
        if (pending.length > ContinuationPolicy.MAX_ROW_BYTES) { throw new Error('接续条目过大') }
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0) })
      }
      if (!header || pending.length > 0 || snapshot.entries.length !== snapshot.state.count ||
        (snapshot.state.target !== '' && !paths.has(snapshot.state.target)) ||
        (snapshot.state.anchor !== '' && !paths.has(snapshot.state.anchor))) {
        throw new Error('接续目录不完整')
      }
      return snapshot
    } finally {
      await fileIo.close(file)
    }
  }
}

import { unifiedDataChannel, uniformDataStruct, uniformTypeDescriptor as utd } from '@kit.ArkData'
import { UploadQueueManager } from './UploadQueueManager'

export class DroppedFiles {
  uris: string[] = []
  unsupported: number = 0
}

export class FileImportResult {
  added: number = 0
  failed: number = 0

  message(): string {
    return this.failed > 0 ? '已加入上传 ' + this.added + ' 项，' + this.failed + ' 项无法导入' :
      '已加入上传：' + this.added + ' 个文件'
  }
}

/** URI adapters end here; all sources use the existing bounded staging queue. */
export class FileImport {
  static readonly maxFiles: number = 500
  static readonly dropTypes: string[] = [utd.UniformDataType.FILE_URI, utd.UniformDataType.FILE,
    utd.UniformDataType.IMAGE, utd.UniformDataType.VIDEO, utd.UniformDataType.AUDIO]

  static fromDrop(data: unifiedDataChannel.UnifiedData): DroppedFiles {
    const records = data.getRecords()
    if (records.length > FileImport.maxFiles) { throw new Error('一次最多拖入 500 个文件') }
    const result = new DroppedFiles()
    const seen = new Set<string>()
    for (const record of records) {
      let uri = ''
      try {
        if (record.getTypes().includes(utd.UniformDataType.FILE_URI)) {
          const file = record.getEntry(utd.UniformDataType.FILE_URI) as uniformDataStruct.FileUri
          if (file !== null && file.fileType !== utd.UniformDataType.FOLDER) { uri = file.oriUri }
        } else if (FileImport.dropTypes.includes(record.getType())) {
          // API 10 File/Image/Video/Audio records expose uri directly. A
          // PixelMap or text/HTML representation is never treated as a file.
          uri = (record as unifiedDataChannel.File).uri
        }
      } catch (_) {}
      if (typeof uri !== 'string' || !uri.startsWith('file://')) { result.unsupported++; continue }
      if (!seen.has(uri)) { seen.add(uri); result.uris.push(uri) }
    }
    if (result.uris.length === 0) { throw new Error('没有可读取的原文件，请从来源应用拖入本地文件') }
    return result
  }

  static async enqueue(queue: UploadQueueManager, uris: string[], target: string, scope: string,
    valid: () => boolean): Promise<FileImportResult> {
    if (uris.length > FileImport.maxFiles) { throw new Error('一次最多导入 500 个文件') }
    if (target === '' || scope === '' || !valid()) { throw new Error('登录状态已改变，请重新选择上传位置') }
    const result = new FileImportResult()
    for (let index = 0; index < uris.length; index++) {
      if (!valid()) { result.failed += uris.length - index; break }
      try {
        const task = await queue.enqueue(uris[index], target, scope)
        if (task.status === 'failed') { result.failed++ } else { result.added++ }
      } catch (_) { result.failed++ }
    }
    return result
  }
}

import { Context } from '@kit.AbilityKit'
import { fileIo, fileUri, picker } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { UgreenError, UgreenErrorKind } from '../ugreen/UgreenErrors'

/**
 * Copies a private cached file to a user-visible location.
 * DOWNLOAD mode creates the app's folder below the public Download directory
 * and returns a URI with the permission needed for the copy.
 */
export class UserFileManager {
  static async saveToDownload(context: Context, sourcePath: string, fileName: string): Promise<string> {
    const saveOptions = new picker.DocumentSaveOptions()
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD
    const documentPicker = new picker.DocumentViewPicker(context)
    const result = await documentPicker.save(saveOptions)
    if (result.length === 0) {
      throw new UgreenError(UgreenErrorKind.UNKNOWN, '已取消保存到本地')
    }
    const targetUri = UserFileManager.joinUri(result[0], UserFileManager.safeFileName(fileName))
    const targetPath = new fileUri.FileUri(targetUri).path
    await fileIo.copyFile(sourcePath, targetPath)
    return targetPath
  }

  static async saveToGallery(context: Context, sourcePath: string, fileName: string,
    isVideo: boolean): Promise<string> {
    const extension = UserFileManager.fileExtension(fileName)
    if (extension.length === 0) {
      throw new UgreenError(UgreenErrorKind.UNKNOWN, '无法识别媒体文件格式')
    }
    const sourceUri = fileUri.getUriFromPath(sourcePath)
    const helper = photoAccessHelper.getPhotoAccessHelper(context)
    const configs: photoAccessHelper.PhotoCreationConfig[] = [{
      title: UserFileManager.fileTitle(fileName),
      fileNameExtension: extension,
      photoType: isVideo ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
      subtype: photoAccessHelper.PhotoSubtype.DEFAULT
    }]
    const targetUris = await helper.showAssetsCreationDialog([sourceUri], configs)
    if (targetUris.length === 0) {
      throw new UgreenError(UgreenErrorKind.UNKNOWN, '已取消保存到图库')
    }
    const sourceFile = await fileIo.open(sourcePath, fileIo.OpenMode.READ_ONLY)
    const targetFile = await fileIo.open(targetUris[0], fileIo.OpenMode.WRITE_ONLY)
    try {
      await fileIo.copyFile(sourceFile.fd, targetFile.fd)
    } finally {
      fileIo.closeSync(sourceFile.fd)
      fileIo.closeSync(targetFile.fd)
    }
    return targetUris[0]
  }

  private static joinUri(directoryUri: string, name: string): string {
    return directoryUri.replace(/\/+$/, '') + '/' + name
  }

  private static safeFileName(name: string): string {
    const trimmed = name.trim()
    if (trimmed.length === 0) {
      return 'ugreen-download-' + Date.now().toString()
    }
    return trimmed.replace(/[\\/:*?"<>|]/g, '_')
  }

  private static fileExtension(name: string): string {
    const safeName = UserFileManager.safeFileName(name)
    const dot = safeName.lastIndexOf('.')
    if (dot <= 0 || dot === safeName.length - 1) {
      return ''
    }
    return safeName.substring(dot + 1).toLowerCase()
  }

  private static fileTitle(name: string): string {
    const safeName = UserFileManager.safeFileName(name)
    const dot = safeName.lastIndexOf('.')
    return dot > 0 ? safeName.substring(0, dot) : safeName
  }
}

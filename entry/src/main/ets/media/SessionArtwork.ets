import { fileIo, fileUri } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'

/** One bounded system cover. The caller owns and releases the returned PixelMap. */
export class SessionArtwork {
  static async decode(uri: string, square: boolean = true): Promise<image.PixelMap | null> {
    if (uri.length === 0) { return null }
    let source: image.ImageSource | null = null
    let file: fileIo.File | null = null
    try {
      const path = uri.startsWith('file://') ? new fileUri.FileUri(uri).path : uri
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY)
      try {
        source = image.createImageSource(file.fd)
        return await SessionArtwork.decodeSource(source, square)
      } catch (_) {
        if (source !== null) { await source.release().catch(() => {}); source = null }
        // Some embedded JPEGs render in ArkUI but fail through FD ImageSource.
        // Retry with owned, bounded compressed bytes.
        const size = (await fileIo.stat(path)).size
        if (size <= 0 || size > 2 * 1024 * 1024) { return null }
        const bytes = new ArrayBuffer(size)
        let read = 0
        while (read < size) {
          const chunk = new ArrayBuffer(Math.min(size - read, 64 * 1024))
          const count = await fileIo.read(file.fd, chunk, { offset: read, length: chunk.byteLength })
          if (count <= 0) { throw new Error('Truncated audio artwork') }
          new Uint8Array(bytes).set(new Uint8Array(chunk, 0, count), read)
          read += count
        }
        source = image.createImageSource(bytes)
        const bitmap = await SessionArtwork.decodeSource(source, square)
        console.info('[SessionArtwork] system artwork decoded from bytes')
        return bitmap
      }
    } catch (_) {
      console.warn('[SessionArtwork] system artwork decode unavailable')
      return null
    }
    finally {
      if (source !== null) { await source.release().catch(() => {}) }
      if (file !== null) { await fileIo.close(file).catch(() => {}) }
    }
  }

  private static async decodeSource(source: image.ImageSource, square: boolean): Promise<image.PixelMap> {
    const info = await source.getImageInfo()
    const width = info.size.width; const height = info.size.height
    if (width <= 0 || height <= 0) { throw new Error('Invalid audio artwork size') }
    const scale = Math.min(1, 800 / Math.max(width, height))
    const bitmap = await source.createPixelMap({
      desiredSize: { width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale)) },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888, editable: true
    })
    try {
      const decoded = await bitmap.getImageInfo()
      const side = Math.min(decoded.size.width, decoded.size.height)
      if (square && decoded.size.width !== decoded.size.height) {
        await bitmap.crop({ x: Math.floor((decoded.size.width - side) / 2),
          y: Math.floor((decoded.size.height - side) / 2), size: { width: side, height: side } })
      }
      // The official system music-cover minimum is 300 x 300. List thumbnails
      // may be 256px; adapt this one system raster without enlarging the list cache.
      if (square && side < 300) { await bitmap.scale(300 / side, 300 / side) }
      return bitmap
    } catch (error) {
      await bitmap.release().catch(() => {})
      throw error as Error
    }
  }

}

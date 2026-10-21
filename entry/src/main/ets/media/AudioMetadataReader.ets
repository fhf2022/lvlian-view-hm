import { fileIo } from '@kit.CoreFileKit'
import { media } from '@kit.MediaKit'
import { AudioTrackInfo } from './AudioPlayerPolicy'

/** Reads tags only from the file already cached by LinkFiles. No network or artwork ownership. */
export class AudioMetadataReader {
  static async read(path: string): Promise<AudioTrackInfo> {
    const result = new AudioTrackInfo()
    let extractor: media.AVMetadataExtractor | null = null
    let file: fileIo.File | null = null
    try {
      extractor = await media.createAVMetadataExtractor()
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY)
      extractor.fdSrc = { fd: file.fd, offset: 0, length: (await fileIo.stat(path)).size }
      const metadata = await extractor.fetchMetadataWithTimeout(1500)
      result.title = (metadata?.title ?? '').trim().substring(0, 512)
      result.artist = (metadata?.artist ?? metadata?.albumArtist ?? '').trim().substring(0, 512)
      result.album = (metadata?.album ?? '').trim().substring(0, 512)
    } catch (_) {
      // Missing/corrupt tags must never prevent audio playback.
    } finally {
      if (extractor !== null) { try { await extractor.release() } catch (_) {} }
      if (file !== null) { try { await fileIo.close(file) } catch (_) {} }
    }
    return result
  }
}

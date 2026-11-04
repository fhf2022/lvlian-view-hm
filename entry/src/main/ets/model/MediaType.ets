import { FileEntry } from './FileEntry'

export type MediaKind = 'image' | 'audio' | 'video' | ''

/** File classification only. Local decoder capabilities belong to the decoder. */
export class MediaType {
  private static readonly IMAGES: Set<string> = new Set<string>([
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff'
  ])
  private static readonly VIDEOS: Set<string> = new Set<string>([
    'mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'ts', 'mpeg', 'mpg',
    'm2ts', 'mts', 'wmv', 'flv', 'f4v', 'rmvb', 'asf'
  ])
  private static readonly AUDIO: Set<string> = new Set<string>([
    'mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg', 'amr'
  ])

  static extension(name: string): string {
    const dot = name.lastIndexOf('.')
    return dot <= 0 || dot === name.length - 1 ? '' : name.substring(dot + 1).toLowerCase()
  }

  static isImage(entry: FileEntry): boolean {
    return !entry.isDirectory && (entry.mimeType.trim().toLowerCase().startsWith('image/') ||
      MediaType.IMAGES.has(MediaType.extension(entry.name)))
  }

  static isVideo(entry: FileEntry): boolean {
    return !entry.isDirectory && (entry.mimeType.trim().toLowerCase().startsWith('video/') ||
      MediaType.VIDEOS.has(MediaType.extension(entry.name)))
  }

  static isAudio(entry: FileEntry): boolean {
    return !entry.isDirectory && (entry.mimeType.trim().toLowerCase().startsWith('audio/') ||
      MediaType.AUDIO.has(MediaType.extension(entry.name)))
  }

  /** Match the established image -> audio -> video open precedence. */
  static kind(entry: FileEntry): MediaKind {
    if (MediaType.isImage(entry)) { return 'image' }
    if (MediaType.isAudio(entry)) { return 'audio' }
    if (MediaType.isVideo(entry)) { return 'video' }
    return ''
  }

  /** Container-based classification for decoders that have a format allowlist. */
  static kindForExtension(extension: string): MediaKind {
    if (MediaType.IMAGES.has(extension)) { return 'image' }
    if (MediaType.AUDIO.has(extension)) { return 'audio' }
    if (MediaType.VIDEOS.has(extension)) { return 'video' }
    return ''
  }
}

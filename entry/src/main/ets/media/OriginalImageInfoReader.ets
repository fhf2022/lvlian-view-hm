export interface OriginalImageInfo {
  width: number
  height: number
  orientation: number
}

export type ImageInfoRange = (offset: number, length: number) => Promise<Uint8Array>

/** Reads original container headers, never a thumbnail. Unknown formats use the
 * caller's complete-file metadata fallback; an uncertain ratio is not published. */
export class OriginalImageInfoReader {
  private start: number = 0
  private window: Uint8Array = new Uint8Array(0)
  private requests: number = 0
  private total: number = 0
  private info: OriginalImageInfo = { width: 0, height: 0, orientation: 1 }
  private size: number
  private range: ImageInfoRange

  constructor(size: number, range: ImageInfoRange) { this.size = size; this.range = range }

  async read(): Promise<OriginalImageInfo | null> {
    try {
      const head = await this.bytes(0, Math.min(16, this.size))
      if (head[0] === 255 && head[1] === 216) { await this.jpeg() }
      else if (this.uint(head, 0, 4) === 2303741511 && this.uint(head, 4, 4) === 218765834) { await this.png() }
      else if (this.text(head, 0, 4) === 'RIFF' && this.text(head, 8, 4) === 'WEBP') { await this.webp(head) }
      else { return null }
      if (this.info.width <= 0 || this.info.height <= 0 || this.info.width > 100000 || this.info.height > 100000) { return null }
      return this.info
    } catch (_) { return null }
  }

  private async bytes(offset: number, length: number): Promise<Uint8Array> {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length <= 0 || offset + length > this.size) {
      throw new Error('Invalid original header range')
    }
    if (offset >= this.start && offset + length <= this.start + this.window.length) {
      return this.window.slice(offset - this.start, offset - this.start + length)
    }
    const count = Math.min(Math.max(length, 64 * 1024), this.size - offset)
    if (++this.requests > 16 || this.total + count > 1024 * 1024) { throw new Error('Original header budget exceeded') }
    this.total += count
    this.window = await this.range(offset, count); this.start = offset
    if (this.window.length !== count) { throw new Error('Truncated original header') }
    return this.window.slice(0, length)
  }

  private uint(bytes: Uint8Array, start: number, length: number, little: boolean = false): number {
    if (start < 0 || start + length > bytes.length) { throw new Error('Truncated image metadata') }
    let value = 0
    for (let index = 0; index < length; index++) { value = value * 256 + bytes[start + (little ? length - index - 1 : index)] }
    return value
  }

  private text(bytes: Uint8Array, start: number, length: number): string {
    let result = ''
    for (let i = start; i < Math.min(start + length, bytes.length); i++) { result += String.fromCharCode(bytes[i]) }
    return result
  }

  private exif(bytes: Uint8Array): void {
    const base = this.text(bytes, 0, 6) === 'Exif\u0000\u0000' ? 6 : 0
    const order = this.text(bytes, base, 2)
    if (order !== 'II' && order !== 'MM') { throw new Error('Invalid EXIF byte order') }
    const little = order === 'II'
    if (this.uint(bytes, base + 2, 2, little) !== 42) { throw new Error('Invalid EXIF header') }
    const ifd = base + this.uint(bytes, base + 4, 4, little)
    const count = this.uint(bytes, ifd, 2, little)
    if (count > 4096 || ifd + 2 + count * 12 > bytes.length) { throw new Error('Truncated EXIF directory') }
    for (let index = 0; index < count; index++) {
      const offset = ifd + 2 + index * 12
      if (this.uint(bytes, offset, 2, little) !== 274) { continue }
      if (this.uint(bytes, offset + 2, 2, little) !== 3 || this.uint(bytes, offset + 4, 4, little) !== 1) {
        throw new Error('Invalid EXIF orientation')
      }
      const value = this.uint(bytes, offset + 8, 2, little)
      if (value < 1 || value > 8) { throw new Error('Invalid EXIF orientation') }
      this.info.orientation = value
      return
    }
  }

  private async jpeg(): Promise<void> {
    let pos = 2
    for (let segment = 0; segment < 512 && pos + 4 <= this.size; segment++) {
      const header = await this.bytes(pos, 4)
      if (header[0] !== 255) { throw new Error('Invalid JPEG marker') }
      const marker = header[1]
      if (marker === 255) { pos++; continue }
      // All APP metadata preceding the image scan has now been examined.
      if (marker === 218 || marker === 217) { return }
      const size = this.uint(header, 2, 2)
      if (size < 2 || pos + 2 + size > this.size) { throw new Error('Invalid JPEG segment') }
      if ([192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207].indexOf(marker) >= 0) {
        const frame = await this.bytes(pos + 4, 5)
        this.info.height = this.uint(frame, 1, 2); this.info.width = this.uint(frame, 3, 2)
      }
      if (marker === 225) {
        const signature = await this.bytes(pos + 4, Math.min(6, size - 2))
        if (this.text(signature, 0, 6) === 'Exif\u0000\u0000') { this.exif(await this.bytes(pos + 4, size - 2)) }
      }
      pos += 2 + size
    }
    throw new Error('Incomplete JPEG metadata')
  }

  private async png(): Promise<void> {
    let pos = 8
    for (let chunk = 0; chunk < 512 && pos + 12 <= this.size; chunk++) {
      const header = await this.bytes(pos, 8)
      const size = this.uint(header, 0, 4); const type = this.text(header, 4, 4)
      if (pos + 12 + size > this.size) { throw new Error('Invalid PNG chunk') }
      if (type === 'IHDR') {
        if (size !== 13) { throw new Error('Invalid PNG header') }
        const dimensions = await this.bytes(pos + 8, 8)
        this.info.width = this.uint(dimensions, 0, 4); this.info.height = this.uint(dimensions, 4, 4)
      }
      // eXIf can follow IDAT. Skip compressed payloads by their declared size.
      if (type === 'eXIf') {
        if (size > 256 * 1024) { throw new Error('EXIF header too large') }
        this.exif(await this.bytes(pos + 8, size))
      }
      if (type === 'IEND') { return }
      pos += 12 + size
    }
    throw new Error('Incomplete PNG metadata')
  }

  private async webp(head: Uint8Array): Promise<void> {
    const end = this.uint(head, 4, 4, true) + 8
    if (end > this.size) { throw new Error('Truncated WebP') }
    let pos = 12
    for (let chunk = 0; chunk < 512 && pos + 8 <= end; chunk++) {
      const header = await this.bytes(pos, 8)
      const type = this.text(header, 0, 4); const size = this.uint(header, 4, 4, true)
      if (pos + 8 + size > end) { throw new Error('Invalid WebP chunk') }
      if (type === 'VP8X' || type === 'VP8 ' || type === 'VP8L') {
        const frame = await this.bytes(pos + 8, Math.min(size, 10))
        if (type === 'VP8X') {
          this.info.width = this.uint(frame, 4, 3, true) + 1; this.info.height = this.uint(frame, 7, 3, true) + 1
        } else if (type === 'VP8 ' && this.info.width === 0) {
          if (this.uint(frame, 3, 3) !== 10289450) { throw new Error('Invalid WebP key frame') }
          this.info.width = this.uint(frame, 6, 2, true) & 16383; this.info.height = this.uint(frame, 8, 2, true) & 16383
        } else if (type === 'VP8L' && this.info.width === 0 && frame[0] === 47) {
          this.info.width = 1 + (frame[1] | ((frame[2] & 63) << 8))
          this.info.height = 1 + ((frame[2] >> 6) | (frame[3] << 2) | ((frame[4] & 15) << 10))
        }
      }
      if (type === 'EXIF') {
        if (size > 256 * 1024) { throw new Error('EXIF header too large') }
        this.exif(await this.bytes(pos + 8, size))
      }
      pos += 8 + size + (size % 2)
    }
    if (pos !== end) { throw new Error('Incomplete WebP metadata') }
  }
}

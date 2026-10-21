export type AudioArtworkRange = (offset: number, length: number) => Promise<Uint8Array>

/** Bounded tag reads only: browsing a song never downloads the audio payload. */
export class AudioArtworkReader {
  static readonly MAX_IMAGE_BYTES: number = 2 * 1024 * 1024
  static readonly MAX_READ_BYTES: number = 3 * 1024 * 1024
  static readonly MAX_REQUESTS: number = 16
  private bytesRead: number = 0
  private requests: number = 0
  private windowStart: number = 0
  private window: Uint8Array = new Uint8Array(0)

  private size: number
  private range: AudioArtworkRange

  constructor(size: number, range: AudioArtworkRange) { this.size = size; this.range = range }

  async read(): Promise<Uint8Array> {
    try {
      const header = await this.bytes(0, Math.min(12, this.size))
      if (this.text(header, 0, 3) === 'ID3') { return await this.id3(header) }
      if (this.text(header, 0, 4) === 'fLaC') { return await this.flac() }
      if (this.text(header, 4, 4) === 'ftyp') { return await this.atoms(0, this.size, 0) }
    } catch (_) {
      // Corrupt, oversized or unsupported tags retain the ordinary audio icon.
    }
    return new Uint8Array(0)
  }

  private async bytes(offset: number, length: number): Promise<Uint8Array> {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length <= 0 ||
      offset + length > this.size) { throw new Error('Invalid audio tag range') }
    if (offset >= this.windowStart && offset + length <= this.windowStart + this.window.length) {
      return this.window.slice(offset - this.windowStart, offset - this.windowStart + length)
    }
    const count = Math.min(Math.max(length, 64 * 1024), this.size - offset)
    if (++this.requests > AudioArtworkReader.MAX_REQUESTS ||
      this.bytesRead + count > AudioArtworkReader.MAX_READ_BYTES) { throw new Error('Audio tag budget exceeded') }
    this.bytesRead += count
    const bytes = await this.range(offset, count)
    if (bytes.length !== count) { throw new Error('Truncated audio tag range') }
    this.windowStart = offset; this.window = bytes
    return bytes.slice(0, length)
  }

  private text(bytes: Uint8Array, start: number, length: number): string {
    let value = ''
    for (let i = start; i < Math.min(bytes.length, start + length); i++) { value += String.fromCharCode(bytes[i]) }
    return value
  }

  private uint(bytes: Uint8Array, start: number, length: number, syncSafe: boolean = false): number {
    if (start < 0 || start + length > bytes.length) { throw new Error('Truncated audio tag') }
    let value = 0
    for (let i = start; i < start + length; i++) {
      if (syncSafe && bytes[i] > 127) { throw new Error('Invalid syncsafe size') }
      value = value * (syncSafe ? 128 : 256) + bytes[i]
    }
    return value
  }

  private deUnsync(bytes: Uint8Array): Uint8Array {
    const output = new Uint8Array(bytes.length)
    let length = 0
    for (let i = 0; i < bytes.length; i++) {
      output[length++] = bytes[i]
      if (bytes[i] === 255 && bytes[i + 1] === 0) { i++ }
    }
    return output.slice(0, length)
  }

  private picture(frame: Uint8Array, legacy: boolean): Uint8Array {
    const encoding = frame[0]
    let offset = legacy ? 4 : 1
    if (!legacy) { while (offset < frame.length && frame[offset++] !== 0) {} }
    const type = frame[offset++]
    if (type !== 3 && type !== 0) { return new Uint8Array(0) }
    if (encoding === 0 || encoding === 3) {
      while (offset < frame.length && frame[offset++] !== 0) {}
    } else if (encoding === 1 || encoding === 2) {
      while (offset + 1 < frame.length) {
        const end = frame[offset] === 0 && frame[offset + 1] === 0
        offset += 2
        if (end) { break }
      }
    } else { return new Uint8Array(0) }
    return this.image(frame.slice(offset))
  }

  private async id3(header: Uint8Array): Promise<Uint8Array> {
    const version = header[3]
    if (version < 2 || version > 4 || (version === 2 && (header[5] & 64) !== 0)) { return new Uint8Array(0) }
    const length = this.uint(header, 6, 4, true)
    if (length > AudioArtworkReader.MAX_IMAGE_BYTES + 64 * 1024 || length === 0) { return new Uint8Array(0) }
    let body = await this.bytes(10, length)
    const unsync = (header[5] & 128) !== 0
    if (version < 4 && unsync) { body = this.deUnsync(body) }
    let offset = 0
    if (version >= 3 && (header[5] & 64) !== 0) {
      offset = this.uint(body, 0, 4, version === 4) + (version === 3 ? 4 : 0)
      if (offset < 4) { return new Uint8Array(0) }
    }
    const frameHeader = version === 2 ? 6 : 10
    for (let frames = 0; frames < 1024 && offset + frameHeader <= body.length; frames++) {
      const id = this.text(body, offset, version === 2 ? 3 : 4)
      const size = this.uint(body, offset + (version === 2 ? 3 : 4), version === 2 ? 3 : 4, version === 4)
      if (size <= 0 || offset + frameHeader + size > body.length) { break }
      if (id === 'APIC' || id === 'PIC') {
        const flags = version === 2 ? 0 : body[offset + 9]
        // Compression/encryption/grouping/data-length prefixes need a decoder;
        // reject them rather than interpreting their prefix as image bytes.
        if ((flags & (version === 4 ? 77 : 224)) === 0) {
          let frame = body.slice(offset + frameHeader, offset + frameHeader + size)
          if (version === 4 && (unsync || (flags & 2) !== 0)) { frame = this.deUnsync(frame) }
          const result = this.picture(frame, version === 2)
          if (result.length > 0) { return result }
        }
      }
      offset += frameHeader + size
    }
    return new Uint8Array(0)
  }

  private async flac(): Promise<Uint8Array> {
    let offset = 4
    for (let blocks = 0; blocks < 64 && offset + 4 <= this.size; blocks++) {
      const header = await this.bytes(offset, 4)
      const length = this.uint(header, 1, 3)
      if ((header[0] & 127) === 6 && length > 0 && length <= AudioArtworkReader.MAX_IMAGE_BYTES + 64 * 1024) {
        const body = await this.bytes(offset + 4, length)
        const type = this.uint(body, 0, 4)
        if (type === 3 || type === 0) {
          let pos = 8 + this.uint(body, 4, 4)
          pos += 4 + this.uint(body, pos, 4)
          pos += 16
          const imageLength = this.uint(body, pos, 4)
          if (imageLength > 0 && pos + 4 + imageLength <= body.length) {
            const result = this.image(body.slice(pos + 4, pos + 4 + imageLength))
            if (result.length > 0) { return result }
          }
        }
      }
      if ((header[0] & 128) !== 0) { break }
      offset += 4 + length
    }
    return new Uint8Array(0)
  }

  private async atoms(start: number, end: number, depth: number): Promise<Uint8Array> {
    if (depth > 6) { return new Uint8Array(0) }
    let offset = start
    for (let atoms = 0; atoms < 128 && offset + 8 <= end; atoms++) {
      const header = await this.bytes(offset, Math.min(16, end - offset))
      const type = this.text(header, 4, 4)
      let size = this.uint(header, 0, 4)
      let prefix = 8
      if (size === 1) { size = this.uint(header, 8, 4) * 4294967296 + this.uint(header, 12, 4); prefix = 16 }
      if (size === 0) { size = end - offset }
      if (!Number.isSafeInteger(size) || size < prefix || offset + size > end) { break }
      if (type === 'covr') {
        const data = await this.bytes(offset + prefix, 16)
        const length = this.uint(data, 0, 4) - 16
        if (this.text(data, 4, 4) === 'data' && length > 0 && length <= AudioArtworkReader.MAX_IMAGE_BYTES &&
          prefix + length + 16 <= size) { return this.image(await this.bytes(offset + prefix + 16, length)) }
      }
      if (['moov', 'udta', 'meta', 'ilst'].indexOf(type) >= 0) {
        const result = await this.atoms(offset + prefix + (type === 'meta' ? 4 : 0), offset + size, depth + 1)
        if (result.length > 0) { return result }
      }
      offset += size
    }
    return new Uint8Array(0)
  }

  private image(bytes: Uint8Array): Uint8Array {
    if (bytes.length > AudioArtworkReader.MAX_IMAGE_BYTES) { return new Uint8Array(0) }
    const jpeg = bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255
    const png = bytes.length >= 8 && this.uint(bytes, 0, 4) === 2303741511 && this.uint(bytes, 4, 4) === 218765834
    return jpeg || png ? bytes : new Uint8Array(0)
  }
}

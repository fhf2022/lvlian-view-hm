import { util } from '@kit.ArkTS'
import { AudioTrackInfo } from './AudioPlayerPolicy'

export type AudioArtworkRange = (offset: number, length: number) => Promise<Uint8Array>

export class AudioTagResult {
  artwork: Uint8Array = new Uint8Array(0)
  info: AudioTrackInfo = new AudioTrackInfo()
}

/** Bounded tag reads only: browsing a song never downloads the audio payload. */
export class AudioArtworkReader {
  static readonly MAX_IMAGE_BYTES: number = 2 * 1024 * 1024
  static readonly MAX_READ_BYTES: number = 3 * 1024 * 1024
  static readonly MAX_REQUESTS: number = 16
  private bytesRead: number = 0
  private requests: number = 0
  private windowStart: number = 0
  private window: Uint8Array = new Uint8Array(0)
  private result: AudioTagResult = new AudioTagResult()
  private wantArtwork: boolean = true
  private wantMetadata: boolean = false
  private primaryArtist: boolean = false
  private atomsRead: number = 0

  private size: number
  private range: AudioArtworkRange

  constructor(size: number, range: AudioArtworkRange) { this.size = size; this.range = range }

  async read(): Promise<Uint8Array> {
    return (await this.readTags(true, false)).artwork
  }

  async readTags(artwork: boolean = true, metadata: boolean = true): Promise<AudioTagResult> {
    this.wantArtwork = artwork; this.wantMetadata = metadata
    this.result = new AudioTagResult(); this.primaryArtist = false; this.atomsRead = 0
    try {
      const header = await this.bytes(0, Math.min(12, this.size))
      if (this.text(header, 0, 3) === 'ID3') { await this.id3(header) }
      else if (this.text(header, 0, 4) === 'fLaC') { await this.flac() }
      else if (this.text(header, 4, 4) === 'ftyp') { await this.atoms(0, this.size, 0) }
    } catch (_) {
      // Keep tags already read; a malformed optional image must not erase them.
    }
    return this.result
  }

  private done(): boolean {
    return (!this.wantArtwork || this.result.artwork.length > 0) &&
      (!this.wantMetadata || (this.result.info.title.length > 0 &&
        this.primaryArtist && this.result.info.album.length > 0))
  }

  private decodeText(bytes: Uint8Array, encoding: number): string {
    if (bytes.length === 0 || bytes.length > 16 * 1024) { return '' }
    let value = ''
    if (encoding === 0) { value = this.text(bytes, 0, bytes.length) }
    else {
      let label = encoding === 3 ? 'utf-8' : 'utf-16be'
      if (encoding === 1) { label = bytes[0] === 254 && bytes[1] === 255 ? 'utf-16be' : 'utf-16le' }
      value = util.TextDecoder.create(label).decodeToString(bytes)
    }
    return value.replace(/\uFEFF/g, '').replace(/\u0000+/g, ' / ')
      .replace(/[\u0001-\u001f\u007f]/g, '').replace(/(?:\s\/\s)+$/, '').trim().substring(0, 512)
  }

  private setText(field: string, value: string): void {
    if (value.length === 0) { return }
    const info = this.result.info
    if (field === 'title' && info.title.length === 0) { info.title = value }
    if (field === 'album' && info.album.length === 0) { info.album = value }
    if (field === 'artist' && !this.primaryArtist) { info.artist = value; this.primaryArtist = true }
    if (field === 'albumArtist' && info.artist.length === 0) { info.artist = value }
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

  private async id3(header: Uint8Array): Promise<void> {
    const version = header[3]
    if (version < 2 || version > 4 || (version === 2 && (header[5] & 64) !== 0)) { return }
    const length = this.uint(header, 6, 4, true)
    if (length === 0 || length > this.size - 10) { return }
    const unsync = (header[5] & 128) !== 0
    let body: Uint8Array | null = null
    // ID3v2.2/2.3 tag-wide unsynchronisation changes physical frame offsets.
    // Decode that bounded tag once; ordinary tags can skip large APIC frames.
    if (version < 4 && unsync) {
      if (length > AudioArtworkReader.MAX_IMAGE_BYTES + 64 * 1024) { return }
      body = this.deUnsync(await this.bytes(10, length))
    }
    const end = body === null ? length : body.length
    let offset = 0
    if (version >= 3 && (header[5] & 64) !== 0) {
      const extended = await this.id3Bytes(body, 0, 4)
      offset = this.uint(extended, 0, 4, version === 4) + (version === 3 ? 4 : 0)
      if (offset < 4 || offset > end) { return }
    }
    const frameHeader = version === 2 ? 6 : 10
    for (let frames = 0; frames < 1024 && offset + frameHeader <= end && !this.done(); frames++) {
      const frame = await this.id3Bytes(body, offset, frameHeader)
      const id = this.text(frame, 0, version === 2 ? 3 : 4)
      const size = this.uint(frame, version === 2 ? 3 : 4, version === 2 ? 3 : 4, version === 4)
      if (size <= 0 || offset + frameHeader + size > end) { break }
      const flags = version === 2 ? 0 : frame[9]
      const picture = this.wantArtwork && this.result.artwork.length === 0 && (id === 'APIC' || id === 'PIC')
      const field = this.wantMetadata ? this.id3TextField(id) : ''
      const limit = picture ? AudioArtworkReader.MAX_IMAGE_BYTES + 64 * 1024 : 16 * 1024
      // Reject compressed/encrypted/grouped frames instead of parsing prefixes as payload.
      if ((picture || field.length > 0) && size <= limit && (flags & (version === 4 ? 77 : 224)) === 0) {
        let payload = await this.id3Bytes(body, offset + frameHeader, size)
        if (version === 4 && (unsync || (flags & 2) !== 0)) { payload = this.deUnsync(payload) }
        if (picture) { this.result.artwork = this.picture(payload, version === 2) }
        else if (payload[0] <= 3) { this.setText(field, this.decodeText(payload.slice(1), payload[0])) }
      }
      offset += frameHeader + size
    }
  }

  private async id3Bytes(body: Uint8Array | null, offset: number, length: number): Promise<Uint8Array> {
    if (body === null) { return await this.bytes(10 + offset, length) }
    if (offset < 0 || offset + length > body.length) { throw new Error('Truncated ID3 tag') }
    return body.slice(offset, offset + length)
  }

  private id3TextField(id: string): string {
    if (id === 'TIT2' || id === 'TT2') { return 'title' }
    if (id === 'TPE1' || id === 'TP1') { return 'artist' }
    if (id === 'TPE2' || id === 'TP2') { return 'albumArtist' }
    if (id === 'TALB' || id === 'TAL') { return 'album' }
    return ''
  }

  private async flac(): Promise<void> {
    let offset = 4
    for (let blocks = 0; blocks < 64 && offset + 4 <= this.size && !this.done(); blocks++) {
      const header = await this.bytes(offset, 4)
      const length = this.uint(header, 1, 3)
      const kind = header[0] & 127
      if (offset + 4 + length > this.size) { return }
      if (kind === 4 && this.wantMetadata && length > 0) {
        await this.vorbisComments(offset + 4, length)
      }
      if (kind === 6 && this.wantArtwork && this.result.artwork.length === 0 &&
        length > 0 && length <= AudioArtworkReader.MAX_IMAGE_BYTES + 64 * 1024) {
        const body = await this.bytes(offset + 4, length)
        const type = this.uint(body, 0, 4)
        if (type === 3 || type === 0) {
          let pos = 8 + this.uint(body, 4, 4)
          pos += 4 + this.uint(body, pos, 4)
          pos += 16
          const imageLength = this.uint(body, pos, 4)
          if (imageLength > 0 && pos + 4 + imageLength <= body.length) {
            this.result.artwork = this.image(body.slice(pos + 4, pos + 4 + imageLength))
          }
        }
      }
      if ((header[0] & 128) !== 0) { break }
      offset += 4 + length
    }
  }

  private littleUint(bytes: Uint8Array, offset: number): number {
    if (offset < 0 || offset + 4 > bytes.length) { throw new Error('Truncated Vorbis comment') }
    return bytes[offset] + bytes[offset + 1] * 256 + bytes[offset + 2] * 65536 + bytes[offset + 3] * 16777216
  }

  private async vorbisComments(start: number, length: number): Promise<void> {
    const end = start + length
    if (length < 8) { return }
    const vendor = this.littleUint(await this.bytes(start, 4), 0)
    let pos = start + 4 + vendor
    if (pos + 4 > end) { return }
    const count = this.littleUint(await this.bytes(pos, 4), 0); pos += 4
    for (let index = 0; index < Math.min(count, 256) && pos + 4 <= end && !this.done(); index++) {
      const size = this.littleUint(await this.bytes(pos, 4), 0); pos += 4
      if (pos + size > end) { return }
      if (size > 0) {
        // Skip large lyrics/embedded-cover comments by offset, just like APIC.
        const prefix = await this.bytes(pos, Math.min(size, 32))
        const name = this.text(prefix, 0, prefix.length)
        const equal = name.indexOf('=')
        const key = name.substring(0, equal).toUpperCase()
        let field = ''
        if (key === 'TITLE') { field = 'title' }
        if (key === 'ARTIST') { field = 'artist' }
        if (key === 'ALBUM') { field = 'album' }
        if (key === 'ALBUMARTIST' || key === 'ALBUM ARTIST') { field = 'albumArtist' }
        if (equal > 0 && field.length > 0 && size > equal + 1 && size <= 16 * 1024) {
          const bytes = await this.bytes(pos + equal + 1, size - equal - 1)
          this.setText(field, this.decodeText(bytes, 3))
        }
      }
      pos += size
    }
  }

  private async atoms(start: number, end: number, depth: number): Promise<void> {
    if (depth > 6) { return }
    let offset = start
    for (let atoms = 0; atoms < 128 && offset + 8 <= end && !this.done(); atoms++) {
      if (++this.atomsRead > 512) { return }
      const header = await this.bytes(offset, Math.min(16, end - offset))
      const type = this.text(header, 4, 4)
      let size = this.uint(header, 0, 4)
      let prefix = 8
      if (size === 1) { size = this.uint(header, 8, 4) * 4294967296 + this.uint(header, 12, 4); prefix = 16 }
      if (size === 0) { size = end - offset }
      if (!Number.isSafeInteger(size) || size < prefix || offset + size > end) { break }
      const picture = type === 'covr' && this.wantArtwork && this.result.artwork.length === 0
      const field = this.wantMetadata ? this.atomTextField(type) : ''
      if ((picture || field.length > 0) && size >= prefix + 16) {
        const data = await this.bytes(offset + prefix, 16)
        const dataSize = this.uint(data, 0, 4)
        const length = dataSize - 16
        const limit = picture ? AudioArtworkReader.MAX_IMAGE_BYTES : 16 * 1024
        if (this.text(data, 4, 4) === 'data' && length > 0 && length <= limit && dataSize <= size - prefix) {
          const bytes = await this.bytes(offset + prefix + 16, length)
          if (picture) { this.result.artwork = this.image(bytes) }
          else {
            const encoding = this.uint(data, 8, 4) & 16777215
            if (encoding === 1 || encoding === 2) { this.setText(field, this.decodeText(bytes, encoding === 1 ? 3 : 2)) }
          }
        }
      }
      if (['moov', 'udta', 'meta', 'ilst'].indexOf(type) >= 0) {
        await this.atoms(offset + prefix + (type === 'meta' ? 4 : 0), offset + size, depth + 1)
      }
      offset += size
    }
  }

  private atomTextField(type: string): string {
    if (type === '©nam') { return 'title' }
    if (type === '©ART') { return 'artist' }
    if (type === 'aART') { return 'albumArtist' }
    if (type === '©alb') { return 'album' }
    return ''
  }

  private image(bytes: Uint8Array): Uint8Array {
    if (bytes.length > AudioArtworkReader.MAX_IMAGE_BYTES) { return new Uint8Array(0) }
    const jpeg = bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255
    const png = bytes.length >= 8 && this.uint(bytes, 0, 4) === 2303741511 && this.uint(bytes, 4, 4) === 218765834
    return jpeg || png ? bytes : new Uint8Array(0)
  }
}

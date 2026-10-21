import { common, wantAgent } from '@kit.AbilityKit'
import { fileIo, fileUri } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { avSession } from '@kit.AVSessionKit'
import { AudioPlayMode } from './AudioPlayerPolicy'
import { VideoBackgroundTaskManager } from './VideoBackgroundTaskManager'

export interface AudioSessionActions {
  play: () => void
  pause: () => void
  stop: () => void
  next: () => void
  previous: () => void
  seek: (positionMs: number) => void
  loopMode: (mode: AudioPlayMode) => void
}

/** LinkFiles owns playback; the system receives the same current-track snapshot. */
export class AudioSessionManager {
  private session: avSession.AVSession | null = null
  private generation: number = 0
  private updateSequence: number = 0
  private metadataSequence: number = 0
  private updates: Promise<void> = Promise.resolve()
  private metadataUpdates: Promise<void> = Promise.resolve()
  private background: VideoBackgroundTaskManager = new VideoBackgroundTaskManager()
  private context: common.UIAbilityContext | null = null
  private path: string = ''
  private title: string = ''
  private artist: string = ''
  private album: string = ''
  private cover: string = ''
  private coverBitmap: image.PixelMap | null = null
  private bitmapUri: string = ''
  private duration: number = 0

  async open(context: common.UIAbilityContext, path: string, title: string, artist: string,
    cover: string, actions: AudioSessionActions): Promise<void> {
    const token = this.generation + 1
    await this.close()
    if (token !== this.generation) { return }
    this.context = context; this.path = path; this.title = title; this.artist = artist; this.cover = cover
    this.album = ''; this.duration = 0
    let created: avSession.AVSession | null = null
    try {
      const session = await avSession.createAVSession(context, 'LinkFilesAudio', 'audio')
      created = session
      if (token !== this.generation) { await session.destroy(); return }
      this.session = session
      // A destroyed session can still have queued callbacks; ignore those.
      const valid = (): boolean => token === this.generation && session === this.session
      session.on('play', (): void => { if (valid()) { actions.play() } })
      session.on('pause', (): void => { if (valid()) { actions.pause() } })
      session.on('stop', (): void => { if (valid()) { actions.stop() } })
      session.on('playNext', (): void => { if (valid()) { actions.next() } })
      session.on('playPrevious', (): void => { if (valid()) { actions.previous() } })
      session.on('seek', (position: number): void => { if (valid()) { actions.seek(position) } })
      session.on('setLoopMode', (mode: avSession.LoopMode): void => {
        if (valid()) { actions.loopMode(mode === avSession.LoopMode.LOOP_MODE_SINGLE ? 'repeat' :
          (mode === avSession.LoopMode.LOOP_MODE_SHUFFLE ? 'shuffle' : 'order')) }
      })
      try {
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
          actionType: wantAgent.OperationType.START_ABILITIES, requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        })
        if (valid()) { await session.setLaunchAbility(agent) }
      } catch (_) {}
      if (!valid()) { return }
      await this.setMetadata(title, artist, '', cover)
      if (valid()) { await session.activate() }
    } catch (_) {
      if (token === this.generation) { this.session = null }
      if (created !== null) { try { await created.destroy() } catch (_) {} }
      console.warn('[LinkFilesAudio] system media session unavailable')
    }
  }

  setMetadata(title: string, artist: string, album: string, cover: string): Promise<void> {
    this.title = title; this.artist = artist; this.album = album; this.cover = cover
    return this.publishMetadata()
  }

  private publishMetadata(): Promise<void> {
    const session = this.session
    const token = this.generation
    const sequence = ++this.metadataSequence
    if (session === null) { return Promise.resolve() }
    this.metadataUpdates = this.metadataUpdates.then(async (): Promise<void> => {
      const valid = (): boolean => token === this.generation && session === this.session && sequence === this.metadataSequence
      if (!valid()) { return }
      const cover = this.cover
      let bitmap: image.PixelMap | null = this.coverBitmap
      const replacing = cover !== this.bitmapUri
      if (replacing) { bitmap = await this.decodeCover(cover) }
      if (!valid()) {
        if (replacing && bitmap !== null) { await bitmap.release().catch(() => {}) }
        return
      }
      try {
        const metadata: avSession.AVMetadata = { assetId: this.path, title: this.title, artist: this.artist,
          album: this.album, duration: this.duration }
        // N-API rejects an explicitly present mediaImage: undefined, including
        // all the valid title/duration fields in that same request.
        if (bitmap !== null) { metadata.mediaImage = bitmap }
        // Private app URIs are not a usable fallback for the system process.
        await session.setAVMetadata(metadata)
      } catch (_) {
        if (replacing && bitmap !== null) { await bitmap.release().catch(() => {}) }
        return
      }
      if (replacing) {
        if (!valid()) {
          if (bitmap !== null) { await bitmap.release().catch(() => {}) }
          return
        }
        const old = this.coverBitmap
        this.coverBitmap = bitmap
        this.bitmapUri = bitmap !== null || cover.length === 0 ? cover : ''
        if (old !== null) { await old.release().catch(() => {}) }
      }
    }).catch(() => {})
    return this.metadataUpdates
  }

  private async decodeCover(uri: string): Promise<image.PixelMap | null> {
    if (uri.length === 0) { return null }
    let source: image.ImageSource | null = null
    let file: fileIo.File | null = null
    try {
      const path = uri.startsWith('file://') ? new fileUri.FileUri(uri).path : uri
      file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY)
      try {
        source = image.createImageSource(file.fd)
        return await this.decodeCoverSource(source)
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
        const bitmap = await this.decodeCoverSource(source)
        console.info('[LinkFilesAudio] system artwork decoded from bytes')
        return bitmap
      }
    } catch (_) {
      console.warn('[LinkFilesAudio] system artwork decode unavailable')
      return null
    }
    finally {
      if (source !== null) { await source.release().catch(() => {}) }
      if (file !== null) { await fileIo.close(file).catch(() => {}) }
    }
  }

  private async decodeCoverSource(source: image.ImageSource): Promise<image.PixelMap> {
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
      if (decoded.size.width !== decoded.size.height) {
        await bitmap.crop({ x: Math.floor((decoded.size.width - side) / 2),
          y: Math.floor((decoded.size.height - side) / 2), size: { width: side, height: side } })
      }
      // The official system music-cover minimum is 300 x 300. List thumbnails
      // may be 256px; adapt this one system raster without enlarging the list cache.
      if (side < 300) { await bitmap.scale(300 / side, 300 / side) }
      return bitmap
    } catch (error) {
      await bitmap.release().catch(() => {})
      throw error as Error
    }
  }

  update(playing: boolean, positionMs: number, durationMs: number, backgroundAllowed: boolean,
    mode: AudioPlayMode = 'order'): void {
    const session = this.session
    if (this.context !== null) { this.background.setPlaying(this.context, session !== null && playing && backgroundAllowed) }
    if (session === null) { return }
    const duration = Number.isFinite(durationMs) ? Math.max(0, Math.floor(durationMs)) : 0
    if (duration !== this.duration) { this.duration = duration; this.publishMetadata() }
    const token = this.generation
    const sequence = ++this.updateSequence
    const position = Number.isFinite(positionMs) ? Math.min(duration, Math.max(0, Math.floor(positionMs))) : 0
    const measuredAt = Date.now()
    this.updates = this.updates.then(async (): Promise<void> => {
      if (sequence !== this.updateSequence || token !== this.generation || this.session !== session) { return }
      await session.setAVPlaybackState({
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: 1, position: { elapsedTime: position, updateTime: measuredAt }, duration: duration,
        loopMode: mode === 'repeat' ? avSession.LoopMode.LOOP_MODE_SINGLE :
          (mode === 'shuffle' ? avSession.LoopMode.LOOP_MODE_SHUFFLE : avSession.LoopMode.LOOP_MODE_LIST)
      })
    }).catch(() => {})
  }

  async close(): Promise<void> {
    this.generation++; this.updateSequence++; this.metadataSequence++
    const session = this.session
    const context = this.context
    const bitmap = this.coverBitmap
    this.session = null; this.context = null; this.coverBitmap = null; this.bitmapUri = ''
    if (context !== null) { await this.background.release(context).catch(() => {}) }
    if (session !== null) {
      try { await session.deactivate() } catch (_) {}
      try { await session.destroy() } catch (_) {}
    }
    if (bitmap !== null) { await bitmap.release().catch(() => {}) }
  }
}

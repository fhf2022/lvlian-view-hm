import { common, wantAgent } from '@kit.AbilityKit'
import { SessionArtwork } from './SessionArtwork'
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
          wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name,
            parameters: { audioPlaybackEntry: true } }],
          actionType: wantAgent.OperationType.START_ABILITIES, requestCode: 7107,
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
      if (replacing) { bitmap = await SessionArtwork.decode(cover) }
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

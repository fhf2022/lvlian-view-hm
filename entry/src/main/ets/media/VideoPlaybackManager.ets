import { fileIo } from '@kit.CoreFileKit'
import { audio } from '@kit.AudioKit'
import { media } from '@kit.MediaKit'
import { VideoSourceHandle } from './VideoTransferManager'

export interface VideoPlaybackCallbacks {
  onTime: (timeMs: number) => void
  onDuration: (durationMs: number) => void
  onSeekDone: (requestedMs: number, actualMs: number) => void
  onState: (state: media.AVPlayerState) => void
  onBuffering: (percent: number) => void
  onSize: (width: number, height: number) => void
  onFirstFrame: () => void
  onError: (error: Object) => void
}

/**
 * Owns one AVPlayer and one optional source FD. The UI only supplies the
 * XComponent surface after it has mounted; this avoids preparing a player
 * against a surface that is not yet real and prevents duplicate video layers.
 */
export class VideoPlaybackManager {
  private player: media.AVPlayer | null = null
  private sourceFd: number = -1
  private handle: VideoSourceHandle | null = null
  private surfaceId: string = ''
  private callbacks: VideoPlaybackCallbacks | null = null
  private generation: number = 0
  private pendingPlay: boolean = false
  private configured: boolean = false
  private configuring: boolean = false
  private pendingPlayerError: Object | null = null
  private playerErrorReported: boolean = false
  private durationHintMs: number = 0
  private currentTimeHintMs: number = 0
  private cachedDurationHintMs: number = 0
  private completionReported: boolean = false

  async open(handle: VideoSourceHandle, positionMs: number,
    callbacks: VideoPlaybackCallbacks, autoPlay: boolean = true): Promise<void> {
    await this.release()
    const player = await media.createAVPlayer()
    this.player = player
    this.handle = handle
    this.callbacks = callbacks
    this.pendingPlay = autoPlay
    this.configured = false
    this.pendingPlayerError = null
    this.playerErrorReported = false
    this.durationHintMs = 0
    this.currentTimeHintMs = Math.max(0, positionMs)
    this.cachedDurationHintMs = 0
    this.completionReported = false
    const generation = this.generation

    player.on('stateChange', (state: media.AVPlayerState): void => {
      if (generation !== this.generation || this.callbacks === null) {
        return
      }
      console.info('[UgreenVideo] player state=' + state)
      if (state === 'completed') {
        this.completionReported = true
      } else if (state === 'playing') {
        this.completionReported = false
      }
      this.callbacks.onState(state)
      if (state === 'prepared' || state === 'playing' || state === 'paused' ||
        state === 'completed') {
        // Some platform versions emit an error while an asynchronous source
        // is still transitioning.  A successful prepared/playing state is
        // authoritative: do not surface that stale event as a failure.
        this.pendingPlayerError = null
        this.playerErrorReported = false
      } else if (state === 'error') {
        const error = this.pendingPlayerError
        this.pendingPlayerError = null
        this.notifyPlayerError(error === null ? new Error('AVPlayer进入 error 状态') : error)
      }
    })
    player.on('timeUpdate', (timeMs: number): void => {
      if (generation !== this.generation || this.callbacks === null) {
        return
      }
      this.currentTimeHintMs = Math.max(0, timeMs)
      this.callbacks.onTime(this.currentTimeHintMs)
      // A few device builds update AVPlayer.state to completed without
      // delivering stateChange. Keep the controls authoritative at the end
      // of the timeline using the documented 100 ms timeUpdate cadence.
      if (!this.completionReported && this.durationHintMs > 0 &&
        this.currentTimeHintMs >= Math.max(0, this.durationHintMs - 200)) {
        this.completionReported = true
        this.callbacks.onState('completed')
      }
    })
    player.on('seekDone', (requestedMs: number): void => {
      if (generation !== this.generation || this.callbacks === null) {
        return
      }
      // seekDone reports the requested position. The SDK requires reading
      // currentTime for the actual sync-frame position.
      const actualMs = Math.max(0, player.currentTime)
      this.currentTimeHintMs = actualMs
      this.callbacks.onSeekDone(Math.max(0, requestedMs), actualMs)
    })
    player.on('durationUpdate', (durationMs: number): void => {
      if (generation !== this.generation || this.callbacks === null) {
        return
      }
      this.durationHintMs = Math.max(0, durationMs)
      this.callbacks.onDuration(this.durationHintMs)
      if (this.cachedDurationHintMs > 0) {
        this.callbacks.onBuffering(this.bufferPercent(
          media.BufferingInfoType.CACHED_DURATION, this.cachedDurationHintMs))
      }
    })
    player.on('bufferingUpdate', (type: media.BufferingInfoType, value: number): void => {
      if (generation !== this.generation || this.callbacks === null) {
        return
      }
      this.callbacks.onBuffering(this.bufferPercent(type, value))
    })
    player.on('videoSizeChange', (width: number, height: number): void => {
      if (generation !== this.generation || this.callbacks === null) {
        return
      }
      this.callbacks.onSize(Math.max(0, width), Math.max(0, height))
    })
    player.on('startRenderFrame', (): void => {
      if (generation !== this.generation || this.callbacks === null) {
        return
      }
      this.callbacks.onFirstFrame()
    })
    player.on('error', (error): void => {
      if (generation !== this.generation || this.callbacks === null) {
        return
      }
      console.error('[UgreenVideo] AVPlayer error: ' + JSON.stringify(error))
      if (player.state === 'error') {
        this.notifyPlayerError(error as Object)
      } else {
        // The error callback can precede the state transition (and on some
        // device releases is emitted for a recoverable setup operation).  Do
        // not open the user-facing dialog until the state machine confirms a
        // terminal error; a later prepared/playing state clears this value.
        this.pendingPlayerError = error as Object
        console.warn('[UgreenVideo] deferred AVPlayer error while state=' + player.state)
      }
    })
    if (this.surfaceId.length > 0) {
      await this.configure(handle, positionMs)
    }
  }

  async attachSurface(surfaceId: string, positionMs: number = 0): Promise<void> {
    this.surfaceId = surfaceId
    if (this.player !== null && this.handle !== null && !this.configured && !this.configuring) {
      await this.configure(this.handle, positionMs)
    } else if (this.player !== null && this.player.state !== 'released') {
      this.player.surfaceId = surfaceId
    }
  }

  async play(): Promise<void> {
    this.pendingPlay = true
    this.completionReported = false
    if (this.player !== null && this.isPlayableState(this.player.state)) {
      await this.player.play()
    }
  }

  async pause(): Promise<void> {
    this.pendingPlay = false
    if (this.player !== null && this.player.state === 'playing') {
      await this.player.pause()
    }
  }

  seek(timeMs: number): void {
    if (this.player === null || !this.isSeekableState(this.player.state)) {
      return
    }
    const targetMs = Math.max(0, Math.floor(timeMs))
    if (this.durationHintMs <= 0 || targetMs < this.durationHintMs - 200) {
      this.completionReported = false
    }
    this.player.seek(targetMs)
  }

  setMuted(muted: boolean): void {
    if (this.player === null || !this.isPlayableState(this.player.state)) {
      return
    }
    this.player.setVolume(muted ? 0 : 1)
  }

  setPlaybackRate(rate: number): boolean {
    if (this.player === null || !this.isPlayableState(this.player.state)) {
      return false
    }
    try {
      // API 20+ accepts a continuous rate from 0.125x through 4x.
      this.player.setPlaybackRate(Math.min(4, Math.max(0.125, rate)))
      return true
    } catch (error) {
      console.warn('[UgreenVideo] set playback rate failed: ' + JSON.stringify(error))
      return false
    }
  }

  currentTime(): number {
    if (this.player === null || !this.isSeekableState(this.player.state)) {
      return 0
    }
    return Math.max(0, this.player.currentTime)
  }

  state(): media.AVPlayerState | null {
    return this.player === null ? null : this.player.state
  }

  async release(): Promise<void> {
    this.generation += 1
    const player = this.player
    const sourceFd = this.sourceFd
    this.player = null
    this.sourceFd = -1
    this.handle = null
    this.surfaceId = ''
    this.callbacks = null
    this.pendingPlay = false
    this.configured = false
    this.configuring = false
    this.pendingPlayerError = null
    this.playerErrorReported = false
    this.durationHintMs = 0
    this.currentTimeHintMs = 0
    this.cachedDurationHintMs = 0
    this.completionReported = false
    if (player !== null) {
      try {
        if (player.state !== 'released') {
          await player.release()
        }
      } catch (_) {
        // Player release is best effort during page teardown.
      }
    }
    if (sourceFd >= 0) {
      try {
        fileIo.closeSync(sourceFd)
      } catch (_) {
        // The media service may already have closed the descriptor.
      }
    }
  }

  private async configure(handle: VideoSourceHandle, positionMs: number): Promise<void> {
    const player = this.player
    if (player === null || this.configured || this.configuring || this.surfaceId.length === 0) {
      return
    }
    this.configuring = true
    const generation = this.generation
    let openedFd: number = -1
    // Native AVPlayer buffering is the producer/consumer pipeline described
    // in the official network-video guide.  Keep the start watermark small
    // enough for quick playback while retaining a bounded ahead buffer.
    const playbackStrategy: media.PlaybackStrategy = {
      preferredBufferDurationForPlaying: 0.3,
      preferredBufferDuration: 20,
      // The poster remains visible while the player is prepared. Rendering
      // frame zero here makes the native Surface flash before playback (and
      // before a saved position has finished seeking).
      showFirstFrameOnPrepare: false
    }
    try {
      // AVPlayer starts in idle.  The source assignment is the state
      // transition to initialized; surface/audio/scale are static properties
      // and are only valid after that transition (see MediaKit AVPlayer
      // state machine).  Setting them first makes prepare fail with 5400102.
      if (handle.localPath.length > 0) {
        const sourceFile = await fileIo.open(handle.localPath, fileIo.OpenMode.READ_ONLY)
        openedFd = sourceFile.fd
        console.info('[UgreenVideo] configure local open path=' + handle.localPath +
          ' fd=' + openedFd + ' state=' + player.state)
        if (!this.isCurrentPlayer(player, generation)) {
          return
        }
        this.sourceFd = openedFd
        openedFd = -1
        player.fdSrc = {
          fd: this.sourceFd,
          offset: 0,
          length: fileIo.statSync(handle.localPath).size
        }
        console.info('[UgreenVideo] configure local fdSrc set state=' + player.state +
          ' fd=' + this.sourceFd)
      } else if (handle.mediaSource !== null) {
        await player.setMediaSource(handle.mediaSource, playbackStrategy)
        console.info('[UgreenVideo] configure mediaSource set state=' + player.state)
      } else {
        throw new Error('视频没有可用数据源')
      }

      if (!this.isCurrentPlayer(player, generation)) {
        return
      }
      if (player.state === 'idle') {
        // setMediaSource() may resolve before the media service publishes the
        // initialized state.  Static AVPlayer properties and prepare() are
        // state-gated, so wait for the real state transition instead of
        // guessing a render/timer frame.
        await this.waitForInitialized(player, generation)
      }
      if (player.state !== 'initialized') {
        throw new Error('视频数据源未进入 initialized 状态: ' + player.state)
      }
      player.surfaceId = this.surfaceId
      player.audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MOVIE,
        rendererFlags: 0
      }
      // FIT stretches the decoded frame to the complete surface and therefore
      // changes its aspect ratio when the window is portrait/landscape. The
      // Video component's ImageFit.Contain equivalent for AVPlayer is
      // SCALED_ASPECT: keep the source ratio and center any required bars.
      player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT
      if (handle.mediaSource === null) {
        // A local FD does not go through setMediaSource(), so apply the same
        // strategy at the initialized state before prepare().
        await player.setPlaybackStrategy(playbackStrategy)
      }
      await player.prepare()
      if (!this.isCurrentPlayer(player, generation)) {
        return
      }
      this.configured = true
      if (this.callbacks !== null) {
        if (player.duration > 0) {
          this.callbacks.onDuration(player.duration)
        }
        if (player.width > 0 && player.height > 0) {
          this.callbacks.onSize(player.width, player.height)
        }
      }
      if (positionMs > 0 && player.duration > positionMs && this.isSeekableState(player.state)) {
        // AVPlayer.seek() is asynchronous. The SDK defines seekDone as the
        // point at which the request has taken effect, so playback must not
        // start until that event arrives or frame zero can be submitted first.
        await this.seekBeforePlayback(player, generation, Math.floor(positionMs))
        if (!this.isCurrentPlayer(player, generation)) {
          return
        }
      }
      if (this.pendingPlay) {
        await player.play()
        // Some device builds complete play() without publishing a
        // stateChange('playing') event to this listener.  A fulfilled play()
        // is the authoritative completion of the requested transition, so
        // synchronize the page state here as well.
        if (this.isCurrentPlayer(player, generation) && this.callbacks !== null) {
          this.callbacks.onState('playing')
        }
      }
    } finally {
      if (openedFd >= 0) {
        try {
          fileIo.closeSync(openedFd)
        } catch (_) {
          // The descriptor may already have been closed by player teardown.
        }
      }
      this.configuring = false
    }
  }

  private isCurrentPlayer(player: media.AVPlayer, generation: number): boolean {
    return generation === this.generation && this.player === player &&
      player.state !== 'released'
  }

  /** Convert the two different network buffering callbacks to one UI value. */
  private bufferPercent(type: media.BufferingInfoType, value: number): number {
    if (type === media.BufferingInfoType.CACHED_DURATION) {
      this.cachedDurationHintMs = Math.max(0, value)
      if (this.durationHintMs <= 0) {
        return 0
      }
      const bufferedUntil = this.currentTimeHintMs + this.cachedDurationHintMs
      return Math.max(0, Math.min(100, bufferedUntil / this.durationHintMs * 100))
    }
    if (type === media.BufferingInfoType.BUFFERING_PERCENT) {
      return Math.max(0, Math.min(100, value))
    }
    if (type === media.BufferingInfoType.BUFFERING_END) {
      return 100
    }
    if (type === media.BufferingInfoType.BUFFERING_START) {
      return 0
    }
    return Math.max(0, Math.min(100, value))
  }

  private notifyPlayerError(error: Object): void {
    if (this.playerErrorReported || this.callbacks === null) {
      return
    }
    this.playerErrorReported = true
    this.callbacks.onError(error)
  }

  private waitForInitialized(player: media.AVPlayer, generation: number): Promise<void> {
    if (player.state === 'initialized') {
      return Promise.resolve()
    }
    return new Promise<void>((resolve, reject) => {
      let settled: boolean = false
      const finish = (error: Error | null): void => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timeoutId)
        player.off('stateChange', onState)
        if (error === null) {
          resolve()
        } else {
          reject(error)
        }
      }
      const onState = (state: media.AVPlayerState, _reason: media.StateChangeReason): void => {
        console.info('[UgreenVideo] wait initialized state=' + state)
        if (state === 'initialized') {
          finish(null)
        } else if (state === 'error' || state === 'released') {
          finish(new Error('视频数据源状态异常: ' + state))
        }
      }
      // The web player allows up to one fragment timeout while the transcode
      // service publishes its first playlist.  A five-second guard made a
      // healthy remote HLS source look like a playback failure on a relay
      // with a cold decoder, so leave enough time for the native source to
      // reach initialized while still bounding a genuinely dead request.
      const timeoutId = setTimeout((): void => {
        if (generation === this.generation && this.player === player) {
          finish(new Error('视频数据源等待 initialized 超时，当前状态: ' + player.state))
        } else {
          finish(new Error('视频播放器已切换'))
        }
      }, 30000)
      player.on('stateChange', onState)
      if (player.state === 'initialized') {
        finish(null)
      }
    })
  }

  private seekBeforePlayback(player: media.AVPlayer, generation: number,
    targetMs: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled: boolean = false
      const finish = (error: Error | null): void => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timeoutId)
        player.off('seekDone', onSeekDone)
        if (error === null) {
          resolve()
        } else {
          reject(error)
        }
      }
      const onSeekDone = (requestedMs: number): void => {
        if (Math.abs(requestedMs - targetMs) <= 1) {
          finish(null)
        }
      }
      const timeoutId = setTimeout((): void => {
        if (!this.isCurrentPlayer(player, generation)) {
          finish(new Error('视频播放器已切换'))
          return
        }
        finish(new Error('视频恢复播放位置超时'))
      }, 30000)
      player.on('seekDone', onSeekDone)
      player.seek(targetMs)
    })
  }

  private isPlayableState(state: media.AVPlayerState): boolean {
    return state === 'prepared' || state === 'playing' || state === 'paused' ||
      state === 'completed'
  }

  private isSeekableState(state: media.AVPlayerState): boolean {
    return this.isPlayableState(state)
  }
}

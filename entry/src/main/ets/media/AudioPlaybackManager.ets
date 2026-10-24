import { fileIo } from '@kit.CoreFileKit'
import { media } from '@kit.MediaKit'
import { DownloadDescriptor } from '../model/FileEntry'

export type AudioTimeListener = (timeMs: number) => void
export type AudioDurationListener = (durationMs: number) => void
export type AudioStateListener = (state: media.AVPlayerState) => void
export type AudioErrorListener = (error: Object) => void

/**
 * Owns one AVPlayer and either its local FD or a transient authenticated URL.
 * Network playback uses MediaKit buffering, never a whole-file staging download.
 */
export class AudioPlaybackManager {
  private player: media.AVPlayer | null = null
  private sourceFd: number = -1
  private source: string | DownloadDescriptor = ''
  private timeListener: AudioTimeListener | null = null
  private durationListener: AudioDurationListener | null = null
  private stateListener: AudioStateListener | null = null
  private errorListener: AudioErrorListener | null = null
  private operation: number = 0
  private cancelInitialization: ((error?: Object) => void) | null = null
  private pendingSeek: number = -1
  private seekTimer: number = -1
  private seekResolve: ((completed: boolean) => void) | null = null

  async open(source: string | DownloadDescriptor, onTime: AudioTimeListener, onDuration: AudioDurationListener,
    onState: AudioStateListener, onError: AudioErrorListener, positionMs: number = 0): Promise<void> {
    const token = this.operation + 1
    await this.release()
    if (token !== this.operation) { return }
    const player = await media.createAVPlayer()
    if (token !== this.operation) { await player.release().catch(() => {}); return }
    let sourceFd = -1
    if (typeof source === 'string') {
      try {
        sourceFd = (await fileIo.open(source, fileIo.OpenMode.READ_ONLY)).fd
      } catch (error) {
        await player.release().catch(() => {})
        throw error as Error
      }
    }
    if (token !== this.operation) {
      await player.release().catch(() => {})
      if (sourceFd >= 0) { fileIo.closeSync(sourceFd) }
      return
    }
    this.player = player
    this.sourceFd = sourceFd
    this.source = source
    this.timeListener = onTime
    this.durationListener = onDuration
    this.stateListener = onState
    this.errorListener = onError
    let initialized: (() => void) | null = null

    player.on('stateChange', (state: media.AVPlayerState) => {
      if (this.player !== player || token !== this.operation) { return }
      if (state === 'initialized') { initialized?.() }
      if (this.stateListener !== null) {
        this.stateListener(state)
      }
    })
    player.on('timeUpdate', (timeMs: number) => {
      if (this.player !== player || token !== this.operation) { return }
      if (this.pendingSeek >= 0) { return }
      if (this.timeListener !== null) {
        this.timeListener(timeMs)
      }
    })
    player.on('seekDone', (timeMs: number) => {
      if (this.player !== player || token !== this.operation || this.pendingSeek < 0) { return }
      // A rapid second seek may precede the first seekDone event.
      if (Math.abs(timeMs - this.pendingSeek) > 1500) { return }
      this.clearSeek(true)
      this.timeListener?.(timeMs)
    })
    player.on('durationUpdate', (durationMs: number) => {
      if (this.player !== player || token !== this.operation) { return }
      if (this.durationListener !== null) {
        this.durationListener(durationMs)
      }
    })
    player.on('error', (error) => {
      if (this.player !== player || token !== this.operation) { return }
      if (this.cancelInitialization !== null) { this.cancelInitialization(error as Object) }
      else { this.errorListener?.(error as Object) }
    })

    try {
      // MediaKit accepts prepare only after the initialized state event.
      // A slow source assignment must also be cancellable when Back is tapped.
      await new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
        let finished = false
        const timer = setTimeout((): void => { this.cancelInitialization?.() }, 15000)
        initialized = (): void => {
          if (finished) { return }
          finished = true; clearTimeout(timer); this.cancelInitialization = null; resolve()
        }
        this.cancelInitialization = (error?: Object): void => {
          if (finished) { return }
          finished = true; clearTimeout(timer); this.cancelInitialization = null
          reject(error !== undefined ? error as Error : new Error('音频准备已取消或超时'))
        }
        try {
          this.assignSource(player).catch((error: Object): void => {
            if (this.player === player && token === this.operation) { this.cancelInitialization?.(error) }
          })
          if (player.state === 'initialized') { initialized() }
        } catch (error) {
          this.cancelInitialization()
        }
      })
      if (this.player !== player || token !== this.operation) { return }
      await player.prepare()
      if (this.player !== player || token !== this.operation) { return }
      if (positionMs > 0 && positionMs < player.duration) {
        const completed = await this.seek(positionMs)
        if (this.player !== player || token !== this.operation) { return }
        if (!completed) { throw new Error('无法恢复音频播放进度') }
      }
    } catch (error) {
      if (this.player === player) { await this.release() }
      throw error as Error
    }
    if (this.player !== player || token !== this.operation) { return }
    if (player.duration > 0 && this.durationListener !== null) {
      this.durationListener(player.duration)
    }
  }

  async play(): Promise<void> {
    if (this.player !== null) {
      await this.player.play()
    }
  }

  async pause(): Promise<void> {
    if (this.player !== null && this.player.state === 'playing') {
      await this.player.pause()
    }
  }

  async rewind(): Promise<void> {
    const player = this.player
    if (player === null) {
      return
    }
    if (player.state === 'prepared' || player.state === 'playing' ||
      player.state === 'paused' || player.state === 'completed') {
      await player.stop()
    }
    if (player.state === 'stopped' || player.state === 'error' || player.state === 'prepared') {
      await player.reset()
      await this.assignSource(player)
      await player.prepare()
      if (player.duration > 0 && this.durationListener !== null) {
        this.durationListener(player.duration)
      }
    }
  }

  isSeeking(): boolean { return this.pendingSeek >= 0 }

  isReady(): boolean {
    const player = this.player
    return player !== null && (player.state === 'prepared' || player.state === 'playing' ||
      player.state === 'paused' || player.state === 'completed')
  }

  async seek(timeMs: number): Promise<boolean> {
    if (this.player === null) {
      return false
    }
    if (this.player.state === 'prepared' || this.player.state === 'playing' ||
      this.player.state === 'paused' || this.player.state === 'completed') {
      if (!Number.isFinite(timeMs)) { return false }
      const target = Math.min(this.player.duration, Math.max(0, Math.floor(timeMs)))
      this.clearSeek()
      const player = this.player
      return new Promise<boolean>((resolve: (completed: boolean) => void): void => {
        this.pendingSeek = target
        this.seekResolve = resolve
        this.seekTimer = setTimeout((): void => {
          if (this.player !== player) { return }
          this.clearSeek()
          this.timeListener?.(Math.max(0, player.currentTime))
        }, 2000)
        try { player.seek(target) } catch (_) { this.clearSeek() }
      })
    }
    return false
  }

  async release(): Promise<void> {
    this.operation++
    this.clearSeek()
    this.cancelInitialization?.()
    const player = this.player
    const sourceFd = this.sourceFd
    this.player = null
    this.sourceFd = -1
    this.source = ''
    this.timeListener = null
    this.durationListener = null
    this.stateListener = null
    this.errorListener = null

    if (player !== null) {
      try {
        if (player.state !== 'released') {
          await player.release()
        }
      } catch (_) {
        // Releasing is best effort while leaving the page or replacing a track.
      }
    }
    if (sourceFd >= 0) {
      try {
        fileIo.closeSync(sourceFd)
      } catch (_) {
        // The player may already have closed the descriptor.
      }
    }
  }

  private async assignSource(player: media.AVPlayer): Promise<void> {
    if (typeof this.source === 'string') {
      player.url = 'fd://' + this.sourceFd.toString()
      return
    }
    const source = media.createMediaSourceWithUrl(this.source.url, this.source.headers)
    source.enableOfflineCache(false)
    await player.setMediaSource(source, { preferredBufferDuration: 8 })
  }

  private clearSeek(completed: boolean = false): void {
    if (this.seekTimer >= 0) { clearTimeout(this.seekTimer); this.seekTimer = -1 }
    this.pendingSeek = -1
    const resolve = this.seekResolve
    this.seekResolve = null
    resolve?.(completed)
  }
}

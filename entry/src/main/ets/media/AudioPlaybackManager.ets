import { fileIo } from '@kit.CoreFileKit'
import { media } from '@kit.MediaKit'

export type AudioTimeListener = (timeMs: number) => void
export type AudioDurationListener = (durationMs: number) => void
export type AudioStateListener = (state: media.AVPlayerState) => void
export type AudioErrorListener = (error: Object) => void

/**
 * Keeps the AVPlayer and its file descriptor together. The descriptor must stay
 * open for the whole playback session, and is closed only after AVPlayer.release().
 */
export class AudioPlaybackManager {
  private player: media.AVPlayer | null = null
  private sourceFd: number = -1
  private timeListener: AudioTimeListener | null = null
  private durationListener: AudioDurationListener | null = null
  private stateListener: AudioStateListener | null = null
  private errorListener: AudioErrorListener | null = null

  async open(path: string, onTime: AudioTimeListener, onDuration: AudioDurationListener,
    onState: AudioStateListener, onError: AudioErrorListener): Promise<void> {
    await this.release()

    const player = await media.createAVPlayer()
    const sourceFile = await fileIo.open(path, fileIo.OpenMode.READ_ONLY)
    this.player = player
    this.sourceFd = sourceFile.fd
    this.timeListener = onTime
    this.durationListener = onDuration
    this.stateListener = onState
    this.errorListener = onError

    player.on('stateChange', (state: media.AVPlayerState) => {
      if (this.stateListener !== null) {
        this.stateListener(state)
      }
    })
    player.on('timeUpdate', (timeMs: number) => {
      if (this.timeListener !== null) {
        this.timeListener(timeMs)
      }
    })
    player.on('durationUpdate', (durationMs: number) => {
      if (this.durationListener !== null) {
        this.durationListener(durationMs)
      }
    })
    player.on('error', (error) => {
      if (this.errorListener !== null) {
        this.errorListener(error as Object)
      }
    })

    player.url = 'fd://' + this.sourceFd.toString()
    await player.prepare()
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
      player.url = 'fd://' + this.sourceFd.toString()
      await player.prepare()
      if (player.duration > 0 && this.durationListener !== null) {
        this.durationListener(player.duration)
      }
    }
  }

  seek(timeMs: number): void {
    if (this.player === null) {
      return
    }
    if (this.player.state === 'prepared' || this.player.state === 'playing' ||
      this.player.state === 'paused' || this.player.state === 'completed') {
      this.player.seek(Math.max(0, Math.floor(timeMs)))
    }
  }

  async release(): Promise<void> {
    const player = this.player
    const sourceFd = this.sourceFd
    this.player = null
    this.sourceFd = -1
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
}

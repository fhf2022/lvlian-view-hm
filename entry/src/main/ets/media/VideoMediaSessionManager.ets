import { Context, common, wantAgent } from '@kit.AbilityKit'
import { avSession } from '@kit.AVSessionKit'
import { FileEntry } from '../model/FileEntry'

/** Commands delivered by the HarmonyOS system media center. */
export interface VideoMediaSessionCallbacks {
  onPlay: () => void
  onPause: () => void
  onStop: () => void
  onNext: () => void
  onSeek: (timeMs: number) => void
  /** Called when the system AVCastPicker connects/disconnects a remote sink. */
  onCastConnected?: () => void
  onCastDisconnected?: () => void
  /** Playback position reported by the remote AVCastController. */
  onCastPlayback?: (snapshot: VideoCastPlaybackSnapshot) => void
}

export interface VideoCastPlaybackSnapshot {
  playing: boolean
  positionMs: number
  durationMs: number
}

/** A small, immutable snapshot of the MediaKit player exposed to AVSession. */
export interface VideoMediaPlaybackSnapshot {
  playing: boolean
  prepared: boolean
  completed: boolean
  bufferingPercent: number
  positionMs: number
  durationMs: number
  muted: boolean
  videoWidthPx: number
  videoHeightPx: number
}

/**
 * Publishes the current video to the HarmonyOS system playback center.
 *
 * MediaKit's AVPlayer only renders and controls a player inside the app. It
 * does not automatically create an AVSession, so the system card would have
 * no title, progress, or commands unless this bridge is kept in sync.
 */
export class VideoMediaSessionManager {
  private session: avSession.AVSession | null = null
  private createPromise: Promise<avSession.AVSession | null> | null = null
  private callbacks: VideoMediaSessionCallbacks | null = null
  private operationToken: number = 0
  private wantsActive: boolean = false
  private active: boolean = false
  private updateChain: Promise<void> = Promise.resolve()
  private currentEntry: FileEntry | null = null
  private castController: avSession.AVCastController | null = null
  private castRemoteActive: boolean = false

  private playCommand = (): void => {
    const callbacks = this.callbacks
    if (callbacks !== null) {
      try {
        callbacks.onPlay()
      } catch (error) {
        console.warn('[UgreenAVSession] play command failed: ' + JSON.stringify(error))
      }
    }
  }

  private pauseCommand = (): void => {
    const callbacks = this.callbacks
    if (callbacks !== null) {
      try {
        callbacks.onPause()
      } catch (error) {
        console.warn('[UgreenAVSession] pause command failed: ' + JSON.stringify(error))
      }
    }
  }

  private stopCommand = (): void => {
    const callbacks = this.callbacks
    if (callbacks !== null) {
      try {
        callbacks.onStop()
      } catch (error) {
        console.warn('[UgreenAVSession] stop command failed: ' + JSON.stringify(error))
      }
    }
  }

  private nextCommand = (): void => {
    const callbacks = this.callbacks
    if (callbacks !== null) {
      try {
        callbacks.onNext()
      } catch (error) {
        console.warn('[UgreenAVSession] next command failed: ' + JSON.stringify(error))
      }
    }
  }

  private seekCommand = (timeMs: number): void => {
    const callbacks = this.callbacks
    if (callbacks !== null) {
      try {
        callbacks.onSeek(Math.max(0, Math.floor(timeMs)))
      } catch (error) {
        console.warn('[UgreenAVSession] seek command failed: ' + JSON.stringify(error))
      }
    }
  }

  private outputDeviceCommand = (state: avSession.ConnectionState,
    device: avSession.OutputDeviceInfo): void => {
    this.handleOutputDeviceChange(state, device).catch((error: Object): void => {
      console.warn('[UgreenAVSession] output device callback failed: ' + JSON.stringify(error))
    })
  }

  private castPlaybackCommand = (state: avSession.AVPlaybackState): void => {
    const callbacks = this.callbacks
    if (callbacks === null || !this.castRemoteActive) {
      return
    }
    const playbackState = state.state
    callbacks.onCastPlayback?.({
      playing: playbackState === avSession.PlaybackState.PLAYBACK_STATE_PLAY,
      positionMs: Math.max(0, Math.floor(state.position?.elapsedTime ?? 0)),
      durationMs: Math.max(0, Math.floor(state.duration ?? 0))
    })
  }

  /**
   * Activate (or reuse) the one AVSession belonging to this UIAbility and
   * publish the selected video and its immediate next item.
   */
  async open(context: Context, entry: FileEntry, nextEntry: FileEntry | null,
    snapshot: VideoMediaPlaybackSnapshot, callbacks: VideoMediaSessionCallbacks): Promise<void> {
    const token = this.operationToken + 1
    this.operationToken = token
    this.wantsActive = true
    this.callbacks = callbacks
    this.currentEntry = entry

    const session = await this.ensureSession(context)
    if (session === null || token !== this.operationToken || !this.wantsActive) {
      return
    }

    try {
      if (!this.active) {
        await session.activate()
        this.active = true
        console.info('[UgreenAVSession] activated session=' + session.sessionId +
          ' type=' + session.sessionType)
      }
      if (token !== this.operationToken || !this.wantsActive) {
        return
      }

      // Video sessions default to DISABLE_BACKGROUND_PLAY.  Set the mode
      // explicitly before the ability can be sent to the background, as
      // required by the official AVSession background-playback guidance.
      try {
        await session.setBackgroundPlayMode(avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY)
      } catch (error) {
        console.warn('[UgreenAVSession] set background play mode failed: ' + JSON.stringify(error))
      }
      try {
        // This tells the system AVCastPicker that the session supports URL
        // casting.  Without it the picker can be empty even when a device is
        // available.
        await session.setExtras({ requireAbilityList: ['url-cast'] })
      } catch (error) {
        console.warn('[UgreenAVSession] set cast extras failed: ' + JSON.stringify(error))
      }

      await this.setLaunchAbility(context, session)
      const metadata: avSession.AVMetadata = {
        assetId: entry.path,
        title: entry.name,
        subtitle: 'UGREENlink 视频',
        filter: avSession.ProtocolType.TYPE_CAST_PLUS_STREAM | avSession.ProtocolType.TYPE_DLNA
      }
      if (snapshot.durationMs > 0) {
        metadata.duration = Math.floor(snapshot.durationMs)
      }
      if (nextEntry !== null) {
        metadata.nextAssetId = nextEntry.path
      }
      await session.setAVMetadata(metadata)
      console.info('[UgreenAVSession] metadata published asset=' + entry.path)

      // A compact queue is enough for the media center to expose the next
      // command while avoiding copying the whole remote directory into the
      // system service. The app remains the source of truth for navigation.
      const queue: Array<avSession.AVQueueItem> = [
        {
          itemId: 0,
          description: this.mediaDescription(entry)
        }
      ]
      if (nextEntry !== null) {
        queue.push({
          itemId: 1,
          description: this.mediaDescription(nextEntry)
        })
      }
      await session.setAVQueueTitle('UGREENlink 视频')
      await session.setAVQueueItems(queue)
      await this.writePlaybackState(session, snapshot)
      console.info('[UgreenAVSession] playback state published asset=' + entry.path +
        ' prepared=' + snapshot.prepared + ' playing=' + snapshot.playing)
    } catch (error) {
      // AVSession is an integration convenience. A missing or unavailable
      // system service must never prevent the in-app AVPlayer from opening.
      console.warn('[UgreenAVSession] publish session failed: ' + JSON.stringify(error))
    }
  }

  /** Update metadata/playback position without blocking the video UI. */
  update(snapshot: VideoMediaPlaybackSnapshot): void {
    const session = this.session
    if (session === null || !this.active || !this.wantsActive) {
      return
    }
    const token = this.operationToken
    this.updateChain = this.updateChain.then(async (): Promise<void> => {
      if (this.session !== session || token !== this.operationToken ||
        !this.active || !this.wantsActive) {
        return
      }
      try {
        await this.writePlaybackState(session, snapshot)
      } catch (error) {
        console.warn('[UgreenAVSession] update playback state failed: ' + JSON.stringify(error))
      }
    }).catch((error: Error): void => {
      console.warn('[UgreenAVSession] update queue failed: ' + JSON.stringify(error))
    })
  }

  /** Deactivate and destroy the session so the system card cannot linger. */
  async close(): Promise<void> {
    this.operationToken += 1
    this.wantsActive = false
    this.callbacks = null
    this.active = false
    this.currentEntry = null
    const castController = this.castController
    this.castController = null
    this.castRemoteActive = false
    if (castController !== null) {
      try {
        castController.off('playbackStateChange')
      } catch (error) {
        console.warn('[UgreenAVSession] release cast listener failed: ' + JSON.stringify(error))
      }
    }
    const session = this.session
    this.session = null
    if (session === null) {
      return
    }
    try {
      await session.deactivate()
    } catch (error) {
      console.warn('[UgreenAVSession] deactivate failed: ' + JSON.stringify(error))
    }
    try {
      await session.destroy()
    } catch (error) {
      console.warn('[UgreenAVSession] destroy failed: ' + JSON.stringify(error))
    }
  }

  /**
   * Start the currently selected media on the remote device. The URL must be
   * reachable by the sink; the page obtains a fresh authenticated download
   * URL rather than exposing the app's range-loader MediaSource.
   */
  async startCasting(mediaUri: string, positionMs: number, durationMs: number): Promise<void> {
    const controller = this.castController
    const entry = this.currentEntry
    if (controller === null || entry === null || !this.castRemoteActive) {
      throw new Error('尚未连接投播设备')
    }
    if (mediaUri.trim().length === 0) {
      throw new Error('当前视频没有可投播地址')
    }
    const item: avSession.AVQueueItem = {
      itemId: 0,
      description: {
        assetId: entry.path,
        title: entry.name,
        subtitle: 'UGREENlink 视频',
        mediaUri: mediaUri,
        mediaType: 'VIDEO',
        mediaSize: entry.size,
        startPosition: Math.max(0, Math.floor(positionMs)),
        duration: Math.max(0, Math.floor(durationMs)),
        appName: 'UGREENlink'
      }
    }
    await controller.prepare(item)
    await controller.start(item)
    console.info('[UgreenAVSession] remote cast started asset=' + entry.path)
  }

  async stopCasting(): Promise<void> {
    const session = this.session
    if (session === null) {
      return
    }
    await session.stopCasting()
  }

  async sendCastControl(command: avSession.AVCastControlCommand): Promise<void> {
    const controller = this.castController
    if (controller === null || !this.castRemoteActive) {
      throw new Error('尚未连接投播设备')
    }
    await controller.sendControlCommand(command)
  }

  isCasting(): boolean {
    return this.castRemoteActive && this.castController !== null
  }

  private async ensureSession(context: Context): Promise<avSession.AVSession | null> {
    if (this.session !== null) {
      return this.session
    }
    if (this.createPromise !== null) {
      return this.createPromise
    }

    const promise = avSession.createAVSession(context, 'UGREENlinkVideo', 'video')
      .then((session: avSession.AVSession): avSession.AVSession | null => {
        if (!this.wantsActive) {
          session.destroy().catch((error: Error): void => {
            console.warn('[UgreenAVSession] discard session failed: ' + JSON.stringify(error))
          })
          return null
        }
        this.session = session
        this.registerCommands(session)
        console.info('[UgreenAVSession] created session=' + session.sessionId +
          ' type=' + session.sessionType)
        return session
      })
      .catch((error: Error): avSession.AVSession | null => {
        console.warn('[UgreenAVSession] create session failed: ' + JSON.stringify(error))
        return null
      })
    this.createPromise = promise
    try {
      return await promise
    } finally {
      if (this.createPromise === promise) {
        this.createPromise = null
      }
    }
  }

  private registerCommands(session: avSession.AVSession): void {
    session.on('play', this.playCommand)
    session.on('pause', this.pauseCommand)
    session.on('stop', this.stopCommand)
    session.on('playNext', this.nextCommand)
    session.on('seek', this.seekCommand)
    session.on('outputDeviceChange', this.outputDeviceCommand)
  }

  private async handleOutputDeviceChange(state: avSession.ConnectionState,
    device: avSession.OutputDeviceInfo): Promise<void> {
    const session = this.session
    if (session === null || !this.wantsActive) {
      return
    }
    const isRemote = device.devices.some((candidate: avSession.DeviceInfo): boolean =>
      candidate.castCategory === avSession.AVCastCategory.CATEGORY_REMOTE)
    if (state === avSession.ConnectionState.STATE_CONNECTED && isRemote) {
      if (this.castRemoteActive && this.castController !== null) {
        return
      }
      try {
        const controller = await session.getAVCastController()
        if (this.session !== session || !this.wantsActive) {
          return
        }
        this.castController = controller
        this.castRemoteActive = true
        controller.on('playbackStateChange', 'all', this.castPlaybackCommand)
        this.callbacks?.onCastConnected?.()
        console.info('[UgreenAVSession] remote cast device connected')
      } catch (error) {
        this.castController = null
        this.castRemoteActive = false
        console.warn('[UgreenAVSession] get cast controller failed: ' + JSON.stringify(error))
      }
      return
    }
    if (this.castRemoteActive &&
      (state === avSession.ConnectionState.STATE_DISCONNECTED || !isRemote)) {
      this.disconnectCastController()
    }
  }

  private disconnectCastController(): void {
    const controller = this.castController
    this.castController = null
    this.castRemoteActive = false
    if (controller !== null) {
      try {
        controller.off('playbackStateChange')
      } catch (error) {
        console.warn('[UgreenAVSession] unregister cast state failed: ' + JSON.stringify(error))
      }
    }
    this.callbacks?.onCastDisconnected?.()
    console.info('[UgreenAVSession] remote cast device disconnected')
  }

  /**
   * The media center uses this WantAgent to associate the AVSession with the
   * ability that owns the player (and to bring it back when the card is
   * tapped). Without it, a session can be activated successfully but remain
   * absent or unopenable in the system playback surface on some device builds.
   */
  private async setLaunchAbility(context: Context, session: avSession.AVSession): Promise<void> {
    try {
      const abilityContext = context as common.UIAbilityContext
      const abilityInfo = abilityContext.abilityInfo
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: abilityInfo.bundleName,
            abilityName: abilityInfo.name
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITIES,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      }
      const agent = await wantAgent.getWantAgent(info)
      await session.setLaunchAbility(agent)
    } catch (error) {
      // A launch agent is not required for in-app controls. Keep the session
      // usable if a vendor build rejects the optional agent creation.
      console.warn('[UgreenAVSession] set launch ability failed: ' + JSON.stringify(error))
    }
  }

  private mediaDescription(entry: FileEntry): avSession.AVMediaDescription {
    return {
      assetId: entry.path,
      title: entry.name,
      mediaType: 'video',
      mediaSize: entry.size,
      duration: 0
    }
  }

  private playbackState(snapshot: VideoMediaPlaybackSnapshot): avSession.PlaybackState {
    if (!snapshot.prepared) {
      return avSession.PlaybackState.PLAYBACK_STATE_PREPARE
    }
    if (snapshot.completed) {
      return avSession.PlaybackState.PLAYBACK_STATE_COMPLETED
    }
    if (snapshot.bufferingPercent > 0 && snapshot.bufferingPercent < 100) {
      return avSession.PlaybackState.PLAYBACK_STATE_BUFFERING
    }
    return snapshot.playing
      ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
      : avSession.PlaybackState.PLAYBACK_STATE_PAUSE
  }

  private async writePlaybackState(session: avSession.AVSession,
    snapshot: VideoMediaPlaybackSnapshot): Promise<void> {
    const state: avSession.AVPlaybackState = {
      state: this.playbackState(snapshot),
      speed: 1,
      position: {
        elapsedTime: Math.max(0, Math.floor(snapshot.positionMs)),
        updateTime: Date.now()
      },
      duration: Math.max(0, Math.floor(snapshot.durationMs)),
      muted: snapshot.muted,
      videoWidth: Math.max(0, Math.floor(snapshot.videoWidthPx)),
      videoHeight: Math.max(0, Math.floor(snapshot.videoHeightPx)),
      bufferedTime: Math.max(0, Math.floor(snapshot.durationMs *
        Math.min(100, Math.max(0, snapshot.bufferingPercent)) / 100)),
      activeItemId: 0
    }
    await session.setAVPlaybackState(state)
  }
}

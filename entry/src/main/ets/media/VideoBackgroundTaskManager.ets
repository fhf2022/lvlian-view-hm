import { Context, common, wantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'

/**
 * Keeps the UIAbility alive while an AVPlayer video (or a remote cast) is
 * actually playing in the background.
 *
 * HarmonyOS requires both an AVSession and an AUDIO_PLAYBACK continuous task
 * for this scenario.  The manager is deliberately edge-triggered: pausing or
 * stopping a video releases the task immediately, while a later play command
 * requests it again.
 */
export class VideoBackgroundTaskManager {
  private running: boolean = false
  private taskId: number = -1
  private desired: boolean = false
  private operation: number = 0
  private queue: Promise<void> = Promise.resolve()
  private subscribed: boolean = false
  private cancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (info.id === this.taskId) { this.running = false; this.taskId = -1 }
  }

  setPlaying(context: Context, playing: boolean): void {
    this.desired = playing
    const operation = this.operation + 1
    this.operation = operation
    this.queue = this.queue.then(async (): Promise<void> => {
      if (operation !== this.operation) {
        return
      }
      if (this.desired === this.running) {
        return
      }
      if (this.desired) {
        await this.start(context)
      } else {
        await this.stop(context)
      }
    }).catch((error: Object): void => {
      // A device may not expose continuous tasks or may reject the permission
      // on a preview build.  The in-app player remains usable in that case;
      // the next state edge can retry the request.
      console.warn('[UgreenVideo] background task update failed: ' + JSON.stringify(error))
    })
  }

  async release(context: Context): Promise<void> {
    this.desired = false
    this.operation += 1
    // Teardown is part of the same lane as start/pause. A subsequent video
    // must not observe running=true while the old stop is still in flight.
    const work = this.queue.then(async (): Promise<void> => {
      if (this.subscribed) {
        try { backgroundTaskManager.off('continuousTaskCancel', this.cancelled) } catch (_) {}
        this.subscribed = false
      }
      await this.stop(context)
    })
    this.queue = work.catch((error: Object): void => {
      console.warn('[UgreenVideo] background task release failed: ' + JSON.stringify(error))
    })
    await work
  }

  private async start(context: Context): Promise<void> {
    if (this.running) {
      return
    }
    const abilityContext = context as common.UIAbilityContext
    if (!this.subscribed) {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelled)
      this.subscribed = true
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: abilityContext.abilityInfo.bundleName,
          abilityName: abilityContext.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    const agent = await wantAgent.getWantAgent(info)
    const request = new backgroundTaskManager.ContinuousTaskRequest()
    request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_AUDIO_PLAYBACK]
    // MODE_AUDIO_PLAYBACK pairs with NORMAL_NOTIFICATION. The AVSession
    // subtype belongs to MODE_AV_PLAYBACK_AND_RECORD, not this main mode.
    // With an active AVSession the system still uses its media notification.
    request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION]
    request.wantAgent = agent
    request.combinedTaskNotification = false
    const result = await backgroundTaskManager.startBackgroundRunning(context, request)
    this.taskId = result.continuousTaskId ?? -1
    if (this.taskId < 0) { throw new Error('系统未返回播放任务标识') }
    this.running = true
    console.info('[UgreenVideo] background audioPlayback task started')
  }

  private async stop(context: Context): Promise<void> {
    if (!this.running) {
      return
    }
    try {
      if (this.taskId >= 0) { await backgroundTaskManager.stopBackgroundRunning(context, this.taskId) }
    } finally {
      this.running = false
      this.taskId = -1
      console.info('[UgreenVideo] background audioPlayback task stopped')
    }
  }
}

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
  private desired: boolean = false
  private operation: number = 0
  private queue: Promise<void> = Promise.resolve()

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
    await this.queue.catch((): void => {})
    if (!this.running) {
      return
    }
    await this.stop(context)
  }

  private async start(context: Context): Promise<void> {
    if (this.running) {
      return
    }
    const abilityContext = context as common.UIAbilityContext
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
    // The list overload is the current UIAbility API and is also the form
    // used by the official long-video sample.
    await backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], agent)
    this.running = true
    console.info('[UgreenVideo] background audioPlayback task started')
  }

  private async stop(context: Context): Promise<void> {
    if (!this.running) {
      return
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context)
    } finally {
      this.running = false
      console.info('[UgreenVideo] background audioPlayback task stopped')
    }
  }
}

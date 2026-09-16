import { vibrator } from '@kit.SensorServiceKit'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Haptic feedback for gesture confirmation and warnings.
 *
 * Deliberately small. Haptics earn their place here in exactly four
 * situations, and nothing else is allowed in:
 *
 *   1. A long press was recognised. The finger is covering the row, so the
 *      menu appearing is partly hidden — this is the part the user cannot see.
 *   2. An invisible threshold was crossed, e.g. a dismiss pull has gone far
 *      enough that releasing now will close the viewer.
 *   3. A destructive confirmation went up. It warns *before* the irreversible
 *      step rather than after it.
 *   4. An operation finished, succeeded or failed.
 *
 * Everything else is left alone on purpose. Navigation, tab switches, view
 * mode changes, checkbox toggles, list scrolling, pinch bounds and photo
 * paging all already show their result on screen, and buzzing on top of a
 * visible change is what makes haptics feel cheap.
 *
 * Call sites name a *cue*, never an effect id. Which preset each cue maps to,
 * how hard it is throttled and what it degrades to are decided here, so
 * tuning how restrained the app feels is a one-file change.
 *
 * Every call is made with usage 'touch', which puts it under the system's
 * haptics switch: a user who turns haptics off hears nothing, and this module
 * never has to second-guess that.
 */
export class HapticFeedback {
  // Effects the local device actually reports. Filled asynchronously by
  // prepare(); a missing entry means "not asked yet", which is treated the
  // same as supported so the very first cue is not swallowed.
  private static supported: Map<string, boolean> = new Map<string, boolean>()
  private static probing: boolean = false
  private static lastFiredAt: Map<string, number> = new Map<string, number>()

  private static readonly SOFT: string = 'haptic.effect.soft'
  private static readonly HARD: string = 'haptic.effect.hard'
  private static readonly SHARP: string = 'haptic.effect.sharp'
  private static readonly SUCCESS: string = 'haptic.notice.success'
  private static readonly FAILURE: string = 'haptic.notice.fail'
  private static readonly TICK: string = 'haptic.clock.timer'

  /**
   * Asks the device which presets it has. Safe to call repeatedly and safe to
   * skip: trigger() works without it and simply prefers the primary effect
   * until the answer lands.
   */
  static prepare(): void {
    if (HapticFeedback.probing) {
      return
    }
    HapticFeedback.probing = true
    const ids: string[] = [
      HapticFeedback.SOFT, HapticFeedback.HARD, HapticFeedback.SHARP,
      HapticFeedback.SUCCESS, HapticFeedback.FAILURE, HapticFeedback.TICK
    ]
    for (const id of ids) {
      vibrator.isSupportEffect(id)
        .then((state: boolean): void => {
          HapticFeedback.supported.set(id, state)
        })
        .catch((_: BusinessError): void => {
          HapticFeedback.supported.set(id, false)
        })
    }
  }

  /** A long press was recognised. */
  static longPress(): void {
    HapticFeedback.fire('longPress', HapticFeedback.HARD, HapticFeedback.SOFT, 250)
  }

  /**
   * An invisible threshold was crossed, e.g. the dismiss pull has gone far
   * enough that releasing now will close the image viewer.
   *
   * Soft on purpose. It fires in the middle of a continuous drag, under the
   * user's finger, and a knock there reads as a warning rather than as the
   * quiet "you can let go now" it is meant to be.
   */
  static threshold(): void {
    HapticFeedback.fire('threshold', HapticFeedback.SOFT, HapticFeedback.SOFT, 200)
  }

  /**
   * A bottom-bar button was pressed.
   *
   * The bottom bar is the one surface where every button is a deliberate,
   * single-purpose action with a durable result — switching section, changing
   * the view mode, acting on a selection — so each press earns a confirming
   * knock, not just the mode changes.
   */
  static confirm(): void {
    HapticFeedback.fire('confirm', HapticFeedback.HARD, HapticFeedback.SOFT, 120)
  }

  /** A destructive confirmation is being shown. */
  static warn(): void {
    HapticFeedback.fire('warn', HapticFeedback.SHARP, HapticFeedback.SOFT, 500)
  }

  /** An operation completed successfully. */
  static success(): void {
    HapticFeedback.fire('success', HapticFeedback.SUCCESS, HapticFeedback.SOFT, 300)
  }

  /** An operation failed. */
  static failure(): void {
    HapticFeedback.fire('failure', HapticFeedback.FAILURE, HapticFeedback.SHARP, 300)
  }

  /**
   * One discrete step on a dial-like control. Reserved for the timeline
   * scrubber, and throttled hard because a drag crosses many steps: without
   * the floor this is the one cue that would turn into continuous buzzing.
   */
  static tick(): void {
    HapticFeedback.fire('tick', HapticFeedback.TICK, HapticFeedback.SOFT, 90)
  }

  private static fire(key: string, primary: string, fallback: string, minIntervalMs: number): void {
    const now = Date.now()
    const last = HapticFeedback.lastFiredAt.get(key)
    if (last !== undefined && now - last < minIntervalMs) {
      return
    }
    HapticFeedback.lastFiredAt.set(key, now)
    const effectId = HapticFeedback.supported.get(primary) === false ? fallback : primary
    HapticFeedback.start(effectId, fallback)
  }

  /**
   * Fire-and-forget on purpose. Nothing in the UI should ever wait for the
   * motor, and a device without one, a disabled haptics switch or a rejected
   * call must all end up as a silent no-op rather than an error the caller
   * has to handle.
   */
  private static start(effectId: string, fallback: string): void {
    vibrator.startVibration({
      type: 'preset',
      effectId: effectId,
      count: 1
    }, {
      usage: 'touch'
    }).catch((_: BusinessError): void => {
      if (effectId === fallback) {
        return
      }
      // Remember the miss so later cues skip straight to the fallback, then
      // make this one good.
      HapticFeedback.supported.set(effectId, false)
      HapticFeedback.start(fallback, fallback)
    })
  }
}

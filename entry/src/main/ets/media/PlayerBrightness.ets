import { window } from '@kit.ArkUI'

/** Serialize writes and restoration so a delayed drag cannot dim the page after leaving. */
export class PlayerBrightness {
  private target: window.Window | null = null
  private original: number = -1
  private pending: Promise<void> = Promise.resolve()

  set(target: window.Window, value: number): Promise<void> {
    const next = this.pending.then(async (): Promise<void> => {
      if (this.target === null) {
        this.target = target
        this.original = target.getWindowProperties().brightness
      }
      await target.setWindowBrightness(Math.max(.01, Math.min(1, value / 100)))
    })
    this.pending = next.catch((): void => {})
    return next
  }

  restore(): Promise<void> {
    const next = this.pending.then(async (): Promise<void> => {
      if (this.target !== null) {
        const target = this.target, original = this.original
        await target.setWindowBrightness(original)
        this.target = null
      }
    })
    this.pending = next.catch((): void => {})
    return next
  }
}

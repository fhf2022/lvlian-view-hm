import { common } from '@kit.AbilityKit'
import { image } from '@kit.ImageKit'
import { drawing } from '@kit.ArkGraphics2D'
import { TransferLiveViewPresentation, TRANSFER_RING_BLUE, TRANSFER_RING_TRACK } from './TransferLiveViewPresentation'

export class TransferLiveViewImages {
  badge: image.PixelMap
  ring: image.PixelMap
  constructor(badge: image.PixelMap, ring: image.PixelMap) { this.badge = badge; this.ring = ring }
  async release(): Promise<void> {
    await this.badge.release().catch(() => {})
    await this.ring.release().catch(() => {})
  }
}

/** Two small immutable bitmaps per visible progress change; no frame-rate timer or UI snapshots. */
export class TransferLiveViewAssets {
  private logo: image.PixelMap | null = null

  async create(context: common.UIAbilityContext, value: TransferLiveViewPresentation): Promise<TransferLiveViewImages> {
    if (!this.logo) {
      const bytes = await context.resourceManager.getMediaContent($r('app.media.icon').id)
      const source = image.createImageSource(bytes.buffer as ArrayBuffer)
      try { this.logo = await source.createPixelMap({ desiredSize: { width: 96, height: 96 } }) }
      finally { await source.release() }
    }
    const badge = this.drawLogo()
    try { return new TransferLiveViewImages(badge, this.draw(value)) }
    catch (error) { await badge.release(); throw error as Error }
  }

  private drawLogo(): image.PixelMap {
    const pixels = image.createPixelMapSync(new ArrayBuffer(96 * 96 * 4), {
      editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.PREMUL, size: { width: 96, height: 96 }
    })
    try {
      const canvas = new drawing.Canvas(pixels)
      if (this.logo) { canvas.drawImage(this.logo, 0, 0) }
      return pixels
    } catch (error) { pixels.release().catch(() => {}); throw error as Error }
  }

  private draw(value: TransferLiveViewPresentation): image.PixelMap {
    // 96x96 RGBA = 36 KiB, well below the API 26 192 KiB limit. All glyphs use (48,48).
    const pixels = image.createPixelMapSync(new ArrayBuffer(96 * 96 * 4), {
      editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.PREMUL, size: { width: 96, height: 96 }
    })
    try {
      const canvas = new drawing.Canvas(pixels)
      const pen = new drawing.Pen()
      pen.setAntiAlias(true); pen.setCapStyle(drawing.CapStyle.ROUND_CAP); pen.setStrokeWidth(9)
      pen.setColor(value.dark ? 0xFF5F6773 : TRANSFER_RING_TRACK)
      canvas.attachPen(pen); canvas.drawCircle(48, 48, 41)
      pen.setColor(TRANSFER_RING_BLUE); canvas.attachPen(pen)
      if (value.percent >= 100) { canvas.drawCircle(48, 48, 41) }
      else if (!value.knownSize) { canvas.drawArc({ left: 7, top: 7, right: 89, bottom: 89 }, -90, 90) }
      else if (value.percent > 0) {
        canvas.drawArc({ left: 7, top: 7, right: 89, bottom: 89 }, -90, value.percent * 3.6)
      }
      canvas.detachPen()
      pen.setStrokeWidth(6); pen.setColor(value.dark ? 0xFFFFFFFF : 0xFF172033)
      if (value.phase === 'failed') { pen.setColor(0xFFC48323) }
      canvas.attachPen(pen)
      if (value.phase === 'completed') {
        canvas.drawLine(34, 48, 44, 58); canvas.drawLine(44, 58, 62, 38)
      } else if (value.phase === 'paused') {
        canvas.drawLine(40, 35, 40, 61); canvas.drawLine(56, 35, 56, 61)
      } else if (value.phase === 'failed') {
        canvas.drawLine(48, 33, 48, 52); canvas.drawLine(48, 62, 48, 62)
      } else if (value.direction === 'both') {
        this.arrow(canvas, 38, true, 12); this.arrow(canvas, 58, false, 12)
      } else { this.arrow(canvas, 48, value.direction === 'upload', 15) }
      canvas.detachPen()
      return pixels
    } catch (error) { pixels.release().catch(() => {}); throw error as Error }
  }

  private arrow(canvas: drawing.Canvas, x: number, up: boolean, half: number): void {
    const tip = up ? 48 - half : 48 + half
    const shoulder = up ? tip + half * 0.7 : tip - half * 0.7
    canvas.drawLine(x, 48 - half, x, 48 + half)
    canvas.drawLine(x - half * 0.6, shoulder, x, tip)
    canvas.drawLine(x + half * 0.6, shoulder, x, tip)
  }

  async release(): Promise<void> {
    const logo = this.logo; this.logo = null
    if (logo) { await logo.release().catch(() => {}) }
  }
}

import { ImportLightState, ProximityLighting } from './ProximityLighting'

/** Decorative overlay; each receiver draws only its own light-facing outline. */
@Component
export struct ProximityLightReceiver {
  @Prop mode: string = 'capsule'
  @StorageLink('ugreen.importLight') @Watch('redraw') light: ImportLightState = new ImportLightState()
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  private ready: boolean = false
  private widthVp: number = 0
  private heightVp: number = 0
  private windowX: number = 0
  private windowY: number = 0

  private redraw(): void {
    if (!this.ready) { return }
    this.context.clearRect(0, 0, this.widthVp, this.heightVp)
    if (!this.light.active || this.widthVp <= 2 || this.heightVp <= 2) { return }
    const sx = this.light.x - this.windowX
    const sy = this.light.y - this.windowY
    const dx = sx - Math.max(0, Math.min(this.widthVp, sx))
    const dy = sy - Math.max(0, Math.min(this.heightVp, sy))
    if (Math.hypot(dx, dy) >= ProximityLighting.RANGE) { return }
    // Draw one continuous directional highlight on the material's own edge.
    const cornerRadius = Math.min(this.widthVp, this.heightVp) / 2
    const light = this.context.createRadialGradient(sx, sy, 0, sx, sy, ProximityLighting.RANGE)
    light.addColorStop(0, 'rgba(235,250,255,0.95)')
    light.addColorStop(0.30, 'rgba(235,250,255,0.82)')
    light.addColorStop(0.65, 'rgba(235,250,255,0.35)')
    light.addColorStop(1, 'rgba(235,250,255,0)')
    this.context.beginPath()
    if (this.mode === 'fileTools') {
      const sidePadding = 16
      const circleSize = this.heightVp
      const sortWidth = 140
      const gap = Math.max(0,
        (this.widthVp - sidePadding * 2 - circleSize * 2 - sortWidth) / 2)
      const sortX = sidePadding + circleSize + gap
      const rightX = this.widthVp - sidePadding - circleSize
      this.context.roundRect(sidePadding + 0.9, 0.9,
        circleSize - 1.8, circleSize - 1.8, cornerRadius - 0.9)
      this.context.roundRect(sortX + 0.9, 0.9,
        sortWidth - 1.8, this.heightVp - 1.8, cornerRadius - 0.9)
      this.context.roundRect(rightX + 0.9, 0.9,
        circleSize - 1.8, circleSize - 1.8, cornerRadius - 0.9)
    } else {
      this.context.roundRect(0.9, 0.9,
        this.widthVp - 1.8, this.heightVp - 1.8, cornerRadius - 0.9)
    }
    this.context.strokeStyle = light
    this.context.lineWidth = 1.8
    this.context.stroke()
  }

  build() {
    Canvas(this.context)
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
      .onReady(() => { this.ready = true; this.redraw() })
      .onAreaChange((_, area: Area) => {
        this.widthVp = Number(area.width)
        this.heightVp = Number(area.height)
        this.windowX = Number(area.globalPosition.x)
        this.windowY = Number(area.globalPosition.y)
        this.redraw()
      })
  }
}

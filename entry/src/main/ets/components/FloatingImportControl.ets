import { uiMaterial, LengthMetrics } from '@kit.ArkUI'
import { preferences } from '@kit.ArkData'
import { ImportLightState } from './ProximityLighting'

/** Diameter of the printed highlight, vp. The ball itself is 56vp. */
const HALO: number = 84
const HALF_HALO: number = HALO / 2
/** How far the finger has to travel before the drag takes over, vp. */
const DRAG_SLOP: number = 10

/**
 * Draggable import ball.
 *
 * The immersive material only renders inside a Navigation title bar, so the
 * ball carries a small Navigation host that is exactly as large as the ball and
 * travels with it (see build()).
 */
@Component
export struct FloatingImportControl {
  @Prop viewportWidth: number = 360
  @Prop viewportHeight: number = 800
  @Prop safeTop: number = 96
  @Prop safeBottom: number = 100
  @Link expanded: boolean
  onSelect: (source: string) => void = () => {}
  @State edge: string = 'right'
  @State fraction: number = 0.68
  @State dragging: boolean = false
  @State pressed: boolean = false
  /** Where the finger landed inside the ball, vp. Frozen once the drag starts. */
  @State lightX: number = 28
  @State lightY: number = 28
  @State dragX: number = 0
  @State dragY: number = 0
  private startX: number = 0
  private startY: number = 0
  private startGlobalX: number = 0
  private startGlobalY: number = 0
  private startLocalX: number = 28
  private startLocalY: number = 28
  private prefs: preferences.Preferences | null = null
  private hostWindowX: number = 0
  private hostWindowY: number = 0

  private publishLight(active: boolean): void {
    AppStorage.setOrCreate('ugreen.importLight', new ImportLightState(
      this.hostWindowX + this.x() + 28, this.hostWindowY + this.y() + 28,
      active && !this.expanded))
  }

  aboutToDisappear(): void { this.publishLight(false) }

  /**
   * Create the material for the ball on every render.
   *
   * A fresh instance keeps the native material state (light origin, touch
   * coordinates) on the frame that is currently drawn.
   *
   * lightEffect is left off on purpose. It is the material's own "press point
   * light" (see the immersive light sense best practice): a halo that spreads
   * from the point that was pressed. That halo is anchored where the press
   * started and does not travel with the node, so the moment the ball follows
   * the finger the halo is left behind and slips off the ball - the ball has to
   * print its own highlight for the drag instead (see TouchLight()).
   */
  private surfaceMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      applyShadow: false,
      colorInvert: true,
      interactive: false,
      lightEffect: null
    })
  }

  /** True from touch down until the gesture is released. */
  private lit(): boolean {
    return this.pressed || this.dragging
  }

  aboutToAppear(): void { this.restore() }
  private async restore(): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(getContext(this), 'ugreen-import-control')
      const edge = String(await this.prefs.get('edge', 'right'))
      const fraction = Number(await this.prefs.get('fraction', 0.68))
      const normalized = Number.isFinite(fraction) ? Math.max(0, Math.min(1, fraction)) : 0.68
      this.edge = edge === 'left' ? 'left' : edge === 'right' ? 'right' :
        (normalized < 0.5 ? 'left' : 'right')
      this.fraction = edge === 'top' ? 0 : edge === 'bottom' ? 1 : normalized
    } catch (_) {}
  }
  private maxX(): number { return Math.max(8, this.viewportWidth - 64) }
  private maxY(): number { return Math.max(this.safeTop, this.viewportHeight - this.safeBottom - 56) }
  private circleX(): number {
    if (this.dragging) { return this.dragX }
    return this.edge === 'left' ? 8 : this.maxX()
  }
  private circleY(): number {
    if (this.dragging) { return this.dragY }
    return this.safeTop + this.fraction * (this.maxY() - this.safeTop)
  }
  private surfaceWidth(): number { return this.expanded ? Math.min(216, this.viewportWidth - 16) : 56 }
  private surfaceHeight(): number { return this.expanded ? 160 : 56 }
  private x(): number { return Math.max(8, Math.min(this.circleX(), this.viewportWidth - this.surfaceWidth() - 8)) }
  private y(): number {
    return Math.max(this.safeTop, Math.min(this.circleY(), this.viewportHeight - this.safeBottom - this.surfaceHeight()))
  }
  private changeExpanded(value: boolean): void {
    this.publishLight(false)
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.expanded = value })
  }
  private choose(source: string): void {
    this.changeExpanded(false)
    this.onSelect(source)
  }
  private async dock(): Promise<void> {
    this.publishLight(false)
    const nextEdge = this.dragX - 8 < this.maxX() - this.dragX ? 'left' : 'right'
    const nextFraction = Math.max(0, Math.min(1,
      (this.dragY - this.safeTop) / Math.max(1, this.maxY() - this.safeTop)))
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.edge = nextEdge
      this.fraction = nextFraction
      this.dragging = false
    })
    if (this.prefs !== null) {
      await this.prefs.put('edge', nextEdge)
      await this.prefs.put('fraction', nextFraction)
      await this.prefs.flush()
    }
  }

  @Builder
  MaterialHost() {
    Stack() {
      this.Surface()
    }
    .width('100%').height('100%')
    .clip(false)
    // Pure host: keep it out of the touch test so taps in its empty area reach
    // the file list behind it instead of dying on a full screen transparent node.
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  Choice(symbol: Resource, label: string, source: string) {
    Row({ space: 14 }) {
      SymbolGlyph(symbol).fontSize(23).fontColor([$r('app.color.text_primary')])
      Text(label).fontSize(16).fontColor($r('app.color.text_primary'))
    }
    .width('100%').height(48).padding({ left: 20, right: 16 })
    .onClick(() => this.choose(source))
    .accessibilityText(label)
  }

  /**
   * The highlight, printed by the ball itself.
   *
   * The platform offers no light that can be pinned to the finger while the
   * lit component is moving: the material's press point light is anchored where
   * the press started, and UIDesignKit's point light is documented to sit at
   * its component's centre and not to follow the component's displacement. Both
   * therefore slide off a ball that is dragged. Drawing the halo here, at the
   * point that was pressed, keeps it exactly under the finger for the whole
   * gesture and gives press and drag one identical highlight.
   *
   * The press point is captured on touch down and frozen once the drag starts,
   * so a lagging layout can never push it towards the leading edge.
   */
  @Builder
  TouchLight() {
    Stack() {
      Column()
        .width(HALO).height(HALO)
        .borderRadius(HALF_HALO)
        .radialGradient({
          center: ['50%', '50%'],
          radius: HALF_HALO,
          colors: [
            ['#F2FFFFFF', 0.0],
            ['#CCFFFFFF', 0.18],
            ['#66FFFFFF', 0.45],
            ['#26FFFFFF', 0.75],
            ['#00FFFFFF', 1.0]
          ]
        })
        .position({ x: this.lightX - HALF_HALO, y: this.lightY - HALF_HALO })
    }
    .width('100%').height('100%')
    .borderRadius(this.expanded ? 24 : 28)
    .clip(true)
    .opacity(this.lit() ? 1 : 0)
    .animation({ duration: 140, curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  Surface() {
    Stack() {
      this.TouchLight()
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(26).fontColor([$r('app.color.text_primary')])
      }
        .width(56).height(56).justifyContent(FlexAlign.Center)
        .opacity(this.expanded ? 0 : 1)
        .hitTestBehavior(this.expanded ? HitTestMode.None : HitTestMode.Default)
      if (this.expanded) {
        Column() {
          this.Choice($r('sys.symbol.folder'), '文件', 'files')
          this.Choice($r('sys.symbol.rectangle_on_rectangle'), '图库', 'gallery')
          this.Choice($r('sys.symbol.folder_badge_plus'), '新建文件夹', 'folder')
        }.padding({ top: 8, bottom: 8 })
      }
    }
    .backgroundColor(Color.Transparent)
    .width(this.surfaceWidth()).height(this.surfaceHeight())
    .borderRadius(this.expanded ? 24 : 28)
    .systemMaterial(this.surfaceMaterial())
    // The ball is the only interactive part of this pass through overlay.
    // Blocking the rest of the hierarchy makes sure a press on the ball never
    // also lands on the folder row that happens to sit behind it.
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .monopolizeEvents(true)
    // The navigation host above already sits at the ball position and is
    // exactly as large as the ball, so the surface only fills it.
    .position({ x: 0, y: 0 })
    .onTouch((event: TouchEvent) => {
      if (this.expanded) { return }
      if (event.type === TouchType.Down) {
        this.pressed = true
        if (event.touches.length > 0) {
          this.lightX = event.touches[0].x
          this.lightY = event.touches[0].y
        }
      } else if (event.type === TouchType.Move) {
        // Keep tracking while this is still a press; once the drag owns the
        // gesture the press point stays where it was so it cannot slip away.
        if (!this.dragging && event.touches.length > 0) {
          this.lightX = event.touches[0].x
          this.lightY = event.touches[0].y
        }
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false
      }
      if (!this.dragging) {
        this.startLocalX = this.lightX
        this.startLocalY = this.lightY
      }
      this.publishLight(event.type !== TouchType.Up && event.type !== TouchType.Cancel && this.lit())
    })
    .onClick(() => { if (!this.expanded && !this.dragging) { this.changeExpanded(true) } })
    .accessibilityText(this.expanded ? '导入选项' : '导入文件或图片')
    .gesture(PanGesture({ direction: PanDirection.All, distance: DRAG_SLOP })
      .onActionStart((event: GestureEvent) => {
        if (this.expanded || event.fingerList.length === 0) { return }
        this.startX = this.circleX()
        this.startY = this.circleY()
        this.startGlobalX = event.fingerList[0].globalX
        this.startGlobalY = event.fingerList[0].globalY
        this.dragX = this.startX
        this.dragY = this.startY
        this.dragging = true
        // Freeze the highlight on the point that was actually pressed.
        this.lightX = this.startLocalX
        this.lightY = this.startLocalY
        this.publishLight(true)
      })
      .onActionUpdate((event: GestureEvent) => {
        if (!this.dragging || event.fingerList.length === 0) { return }
        // Global coordinates stay stable while this titlebar itself moves under the finger.
        this.dragX = Math.max(8, Math.min(this.maxX(),
          this.startX + event.fingerList[0].globalX - this.startGlobalX))
        this.dragY = Math.max(this.safeTop, Math.min(this.maxY(),
          this.startY + event.fingerList[0].globalY - this.startGlobalY))
        this.publishLight(true)
      })
      .onActionEnd(() => { if (this.dragging) { this.dock() } })
      .onActionCancel(() => { if (this.dragging) { this.dock() } }))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The material only renders inside a Navigation title bar, so the ball
      // needs this host. The host is kept exactly as large as the ball and is
      // moved with it: a full screen host would put a full screen navigation
      // bar above the page, and that bar takes part in the touch test and
      // swallows every tap meant for the file list below.
      Navigation() {}
        .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
        .title({ builder: this.MaterialHost, height: '100%' }, {
          barStyle: BarStyle.STACK, paddingStart: LengthMetrics.vp(0), paddingEnd: LengthMetrics.vp(0),
          backgroundColor: Color.Transparent
        })
        .width(this.surfaceWidth()).height(this.surfaceHeight())
        .position({ x: this.x(), y: this.y() })
        .backgroundColor(Color.Transparent).clip(false)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%').height('100%')
    .clip(false)
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_, area: Area) => {
      this.hostWindowX = Number(area.globalPosition.x)
      this.hostWindowY = Number(area.globalPosition.y)
      if (this.lit()) { this.publishLight(true) }
    })
  }
}

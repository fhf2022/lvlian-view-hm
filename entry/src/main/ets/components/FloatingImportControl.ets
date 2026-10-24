import { GlassControlGeometry as Glass } from '../ui/GlassControlGeometry'
import { GlassMaterial } from '../ui/GlassMaterial'
import { uiMaterial, LengthMetrics } from '@kit.ArkUI'
import { preferences } from '@kit.ArkData'
import { ImportLightState } from './ProximityLighting'

/**
 * 光晕半径 / 直径，vp（球本体 56vp）。
 *
 * 别较真用 ProximityLighting.RANGE 对齐：那是"光够得着的距离"（超出就不画了），
 * 不是光斑的半径。别处画的是材质边缘上的一圈细高光，视觉上很小；这里是从中心
 * 向外辐射的实心光斑，同样的数值会大得离谱（试过 140 半径 = 280 直径，明显过大）。
 * 就按球本身的尺度给：半径 56（比原来的 42 略大一点）。
 */
const HALF_HALO: number = 56
const HALO: number = HALF_HALO * 2
/** How far the finger has to travel before the drag takes over, vp. */
const DRAG_SLOP: number = 10

/**
 * Draggable import ball.
 *
 * The immersive material only renders inside a Navigation title bar, so the
 * ball uses a visual-only title-bar scope while its exact-size sibling handles
 * content and input (see build()).
 */
@Component
export struct FloatingImportControl {
  @Prop viewportWidth: number = 360
  @Prop viewportHeight: number = 800
  @Prop safeTop: number = 96
  @Prop safeBottom: number = 100
  @Link expanded: boolean
  onSelect: (source: string) => void = () => {}
  onControlAreaChange: (area: Area) => void = () => {}
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
  // 展开菜单里「按下 A、滑到 B 松手 → 执行 B」用：记住按下时落在哪一项。
  private slidePressSource: string = ''
  private prefs: preferences.Preferences | null = null
  private hostWindowX: number = 0
  private hostWindowY: number = 0

  private publishLight(active: boolean): void {
    AppStorage.setOrCreate('ugreen.importLight', new ImportLightState(
      this.hostWindowX + this.x() + 28, this.hostWindowY + this.y() + 28,
      active && !this.expanded))
  }

  aboutToDisappear(): void { this.publishLight(false) }

  // Native light is disabled for the moving ball. TouchLight paints the
  // frozen press point in local coordinates without recreating the material.
  private material: uiMaterial.ImmersiveMaterial = GlassMaterial.importSurface()

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
  private maxX(): number { return Math.max(8, this.viewportWidth - Glass.barHeight - Glass.importPadding) }
  private maxY(): number { return Math.max(this.safeTop, this.viewportHeight - this.safeBottom - Glass.barHeight) }
  private circleX(): number {
    if (this.dragging) { return this.dragX }
    return this.edge === 'left' ? 8 : this.maxX()
  }
  private circleY(): number {
    if (this.dragging) { return this.dragY }
    return this.safeTop + this.fraction * (this.maxY() - this.safeTop)
  }
  private expandedSurfaceWidth(): number { return Math.min(Glass.importWidth, this.viewportWidth - Glass.importPadding * 2) }
  private surfaceWidth(): number { return this.expanded ? this.expandedSurfaceWidth() : Glass.barHeight }
  private surfaceHeight(): number { return this.expanded ? Glass.importHeight : Glass.barHeight }
  private x(): number { return Math.max(8, Math.min(this.circleX(), this.viewportWidth - this.surfaceWidth() - 8)) }
  private y(): number {
    return Math.max(this.safeTop, Math.min(this.circleY(), this.viewportHeight - this.safeBottom - this.surfaceHeight()))
  }
  private changeExpanded(value: boolean): void {
    this.publishLight(false)
    const context = this.getUIContext()
    if (!value) {
      // A system picker can take the window in the same event turn. Dispatch
      // the collapse to the render service immediately so it starts in
      // parallel instead of waiting for the next vsync behind picker startup.
      context.animateToImmediately({ duration: 220, curve: Curve.EaseInOut }, () => {
        this.expanded = false
      })
      return
    }
    context.animateTo({ duration: 220, curve: Curve.EaseInOut }, () => { this.expanded = true })
  }
  // 展开菜单的 onTouch 和条目的 onClick 都会走到这里（容器触摸会截断点击，
  // 两条路都可能触发），加一道时间去重，避免 onSelect 被执行两次。
  private lastChooseAt: number = 0

  private choose(source: string): void {
    const now = Date.now()
    if (now - this.lastChooseAt < 350) {
      return
    }
    this.lastChooseAt = now
    this.changeExpanded(false)
    this.onSelect(source)
  }

  /** 展开菜单里 y 落在第几项（四项等高 48vp，容器上下各 8vp 内边距）。 */
  private sourceAt(y: number): string {
    const index = Math.floor((y - Glass.importPadding) / Glass.importRowHeight)
    if (index < 0 || index > 3) {
      return ''
    }
    const sources: string[] = ['files', 'gallery', 'album', 'folder']
    return sources[index]
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
      this.MaterialSurface()
    }
    .width('100%').height('100%')
    .clip(false)
    // This title builder only supplies the supported material scope. Input is
    // handled by the exact-size Surface sibling in build().
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  MaterialSurface() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(Glass.iconSize)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(Glass.barHeight)
      .height(Glass.barHeight)
      .justifyContent(FlexAlign.Center)
      .opacity(this.expanded ? 0 : 1)

      // The visible choices must stay inside the material subtree for
      // colorInvert to react to the content underneath the floating panel.
      Column() {
        this.ChoiceVisual($r('sys.symbol.folder'), '文件')
        this.ChoiceVisual($r('sys.symbol.picture_on_square'), '图库')
        this.ChoiceVisual($r('sys.symbol.picture_on_square'), '图库文件夹')
        this.ChoiceVisual($r('sys.symbol.folder_badge_plus'), '新建文件夹')
      }
      .width(this.expandedSurfaceWidth())
      .height(Glass.importHeight)
      .padding({ top: Glass.importPadding, bottom: Glass.importPadding })
      .position({ x: 0, y: 0 })
      .opacity(this.expanded ? 1 : 0)
      .animation({ duration: this.expanded ? 120 : 70, curve: Curve.EaseOut })
    }
      .width(this.surfaceWidth()).height(this.surfaceHeight())
      .borderRadius(this.expanded ? 24 : Glass.barHeight / 2)
      .backgroundColor(Color.Transparent)
      .systemMaterial(this.material)
      .position({ x: this.x(), y: this.y() })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  ChoiceVisual(symbol: Resource, label: string) {
    Row({ space: 12 }) {
      SymbolGlyph(symbol)
        .fontSize(Glass.iconSize)
        .fontColor([$r('sys.color.icon_primary')])
      Text(label)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
    }
    .width('100%').height(Glass.importRowHeight).padding({ left: 16, right: 12 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  ChoiceHitTarget(label: string, source: string) {
    Row()
    .width('100%').height(Glass.importRowHeight).padding({ left: 16, right: 12 })
    .onClick(() => this.choose(source))
    .accessibilityText(label)
    .id('import-choice:' + source)
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
          // 和 ProximityLightReceiver 画边缘高光用的是同一组色标
          // （235,250,255 冷白；0.95 / 0.82 / 0.35 / 0 的透明度），只是这里
          // 从中心向外辐射 —— 两处的观感才对得上。
          colors: [
            ['#F2EBFAFF', 0.0],
            ['#D1EBFAFF', 0.30],
            ['#59EBFAFF', 0.65],
            ['#00EBFAFF', 1.0]
          ]
        })
        .position({ x: this.lightX - HALF_HALO, y: this.lightY - HALF_HALO })
    }
    .width('100%').height('100%')
    .borderRadius(this.expanded ? 24 : Glass.barHeight / 2)
    .clip(true)
    .opacity(this.lit() ? 1 : 0)
    .animation({ duration: 140, curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  CollapsedBall() {
    Row()
    .width(Glass.barHeight).height(Glass.barHeight).justifyContent(FlexAlign.Center)
    // The drag recognizer lives on the exact 56vp ball only. Removing the
    // recognizer from the panel ancestor avoids competing with Choice clicks.
    .hitTestBehavior(this.expanded ? HitTestMode.BLOCK_DESCENDANTS : HitTestMode.Default)
    .monopolizeEvents(!this.expanded)
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
    .id('import-open-button')
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

  @Builder
  Surface() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.TouchLight()
      this.CollapsedBall()
      // Keep the choices at their final dimensions while the material surface
      // morphs. If this column follows the shrinking parent, Row/Text is laid
      // out again on every frame and the labels visibly scatter into the ball.
      Column() {
        this.ChoiceHitTarget('文件', 'files')
        this.ChoiceHitTarget('图库', 'gallery')
        this.ChoiceHitTarget('图库文件夹', 'album')
        this.ChoiceHitTarget('新建文件夹', 'folder')
      }
      .width(this.expandedSurfaceWidth())
      .height(Glass.importHeight)
      .padding({ top: Glass.importPadding, bottom: Glass.importPadding })
      .position({ x: 0, y: 0 })
      .opacity(this.expanded ? 1 : 0)
      .animation({ duration: this.expanded ? 120 : 70, curve: Curve.EaseOut })
      .hitTestBehavior(this.expanded ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
      // 「按下 A、滑到 B 松手 → 执行 B」。四项等高 48vp、容器上下各 8vp 内边距，
      // 所以按 y 直接算索引即可。松手仍落在按下的那一项上时不处理——交给 onClick，
      // 两者互补，不会重复执行。
      .onTouch((event: TouchEvent) => {
        if (!this.expanded) {
          return
        }
        const points = event.touches
        if (points.length === 0) {
          return
        }
        // 展开时光感没人发布（CollapsedBall 在 expanded 时直接 return），
        // 由这里接手，光才能跟着手指走。
        this.lightX = points[0].x
        this.lightY = points[0].y
        if (event.type === TouchType.Down) {
          this.pressed = true
          this.publishLight(true)
          this.slidePressSource = this.sourceAt(points[0].y)
          return
        }
        if (event.type === TouchType.Move) {
          return
        }
        // Up / Cancel：一律按「松手时落在哪一项」执行（choose 内部有 350ms 去重，
        // 不会和条目的 onClick 重复执行）；落在菜单外就只收起菜单。
        this.pressed = false
        this.publishLight(false)
        const released = this.sourceAt(points[0].y)
        this.slidePressSource = ''
        if (released.length === 0) {
          this.changeExpanded(false)
          return
        }
        this.choose(released)
      })
    }
    .backgroundColor(Color.Transparent)
    .width(this.surfaceWidth()).height(this.surfaceHeight())
    .borderRadius(this.expanded ? 24 : Glass.barHeight / 2)
    .hitTestBehavior(HitTestMode.Default)
    .position({ x: this.x(), y: this.y() })
    .onAreaChange((_, area: Area) => {
      this.onControlAreaChange(area)
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Keep the title bar full-size so the native material shadow has no local
      // rectangular clipping edge. BLOCK_DESCENDANTS makes this visual-only
      // scope transparent to hit testing, including Navigation's generated bar.
      Navigation() {}
        .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
        .title({ builder: this.MaterialHost, height: '100%' }, {
          barStyle: BarStyle.STACK, paddingStart: LengthMetrics.vp(0), paddingEnd: LengthMetrics.vp(0),
          backgroundColor: Color.Transparent, backgroundBlurStyle: BlurStyle.NONE
        })
        .width('100%').height('100%')
        .backgroundColor(Color.Transparent).clip(false)
        .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)

      // Content and gestures use only the visible control bounds. Nothing in
      // the full-size Navigation above can consume a tap meant for the page.
      this.Surface()
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

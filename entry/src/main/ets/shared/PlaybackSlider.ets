/** Shared by HarmonyCast and LinkFiles. Canonical source: HarmonyCast.
 * Sync/check with scripts/sync-playback-slider.cjs; no player or network dependencies. */
@ComponentV2
export struct PlaybackSlider {
  @Param value: number = 0
  @Param min: number = 0
  @Param max: number = 1
  @Param step: number = 1
  @Param isVertical: boolean = false
  @Param railLength: number = 1
  @Param bufferedValue: number | undefined = undefined
  @Param isEnabled: boolean = true
  @Param label: string = ''
  @Event onPreview: (value: number, active: boolean) => void = () => {}
  @Event onCommit: (value: number) => void = () => {}
  @Event onBegin: () => void = () => {}
  @Event onCancel: () => void = () => {}
  @Local dragging: boolean = false
  @Local previewValue: number = 0
  @Local thumbRatio: number = 0
  @Local thumbVisible: boolean = false
  private thumbMoving: boolean = false
  private motionToken: number = 0
  private cancelled: boolean = false
  private clickCommitted: boolean = false

  aboutToAppear(): void { this.cancelled = false; this.dragging = false; this.resetThumb() }
  aboutToDisappear(): void {
    this.motionToken++; this.thumbMoving = false; this.thumbVisible = false; this.dragging = false
  }

  @Monitor('value')
  private followValue(): void {
    if (!this.thumbVisible && !this.dragging) { this.thumbRatio = this.ratio(this.value) }
  }

  @Monitor('min', 'max', 'railLength', 'isVertical')
  private resetGeometry(): void {
    if (this.dragging) {
      this.cancelled = true
      this.dragging = false
      this.onPreview(this.value, false)
      this.onCancel()
    }
    this.resetThumb()
  }

  private ratio(value: number): number {
    return Math.max(0, Math.min(1, (value - this.min) / Math.max(0.001, this.max - this.min)))
  }

  private displayedValue(): number { return this.dragging ? this.previewValue : this.value }
  private paintedRatio(): number { return this.thumbVisible ? this.thumbRatio : this.ratio(this.displayedValue()) }

  private previewThumb(value: number, animate: boolean): void {
    const target = this.ratio(value)
    this.thumbVisible = true
    if (animate && target === this.thumbRatio) { return }
    if (!animate && !this.thumbMoving) { this.thumbRatio = target; return }
    const token = ++this.motionToken
    this.thumbMoving = animate
    // ArkUI retargets the same property from its current presentation position.
    // A superseded completion must never hide the thumb of a newer touch.
    this.getUIContext().animateTo({ duration: animate ? 160 : 0, curve: Curve.EaseOut,
      onFinish: (): void => {
        if (token !== this.motionToken) { return }
        this.thumbMoving = false
        if (!this.dragging) { this.thumbVisible = false; this.followValue() }
      } }, (): void => { this.thumbRatio = target })
  }

  private finishThumb(): void {
    if (!this.thumbMoving) { this.thumbVisible = false; this.followValue() }
  }

  private resetThumb(): void {
    this.motionToken++
    const moving = this.thumbMoving
    this.thumbMoving = false
    this.thumbVisible = false
    if (moving) {
      this.getUIContext().animateTo({ duration: 0 }, (): void => { this.thumbRatio = this.ratio(this.value) })
    } else { this.thumbRatio = this.ratio(this.value) }
  }

  build(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: this.isVertical ? Alignment.Bottom : Alignment.Start }) {
        Rect().width('100%').height('100%').radius(4).fill('#303237')
        if (this.bufferedValue !== undefined) {
          Rect().width(this.isVertical ? 8 : this.railLength * this.ratio(this.bufferedValue))
            .height(this.isVertical ? this.railLength * this.ratio(this.bufferedValue) : 8).radius(4).fill('#667078')
        }
        Row().width(this.isVertical ? 8 : this.railLength * this.paintedRatio())
          .height(this.isVertical ? this.railLength * this.paintedRatio() : 8)
          .borderRadius(4).backgroundColor('#DEE1E6')
      }.width(this.isVertical ? 8 : this.railLength).height(this.isVertical ? this.railLength : 8)
        .position({ x: this.isVertical ? 18 : 0, y: this.isVertical ? 0 : 18 }).hitTestBehavior(HitTestMode.None)
      Slider({ value: this.displayedValue(), min: this.min, max: this.max,
        step: this.step, style: SliderStyle.OutSet,
        direction: this.isVertical ? Axis.Vertical : Axis.Horizontal, reverse: this.isVertical })
        .width(this.isVertical ? 44 : this.railLength + 30).height(this.isVertical ? this.railLength + 30 : 44)
        .blockSize({ width: 30, height: 30 }).trackThickness(8)
        // Native Begin already contains the pressed position. Preview it immediately,
        // then commit once on release; Down must not write the old value back.
        .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK)
        .trackColor(Color.Transparent).selectedColor(Color.Transparent)
        // Keep native input/hit geometry, paint one circle with an owned completion.
        .blockStyle({ type: SliderBlockType.SHAPE,
          shape: new Circle({ width: 30, height: 30 }).fill(Color.Transparent) })
        .blockColor(Color.Transparent).blockBorderWidth(0)
        .position({ x: this.isVertical ? 0 : -15, y: this.isVertical ? -15 : 0 }).enabled(this.isEnabled)
        .id(this.label).accessibilityText(this.label)
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.cancelled = false
            this.clickCommitted = false
          } else if (event.type === TouchType.Cancel) {
            this.cancelled = true
            this.dragging = false
            this.resetThumb()
            this.onPreview(this.value, false)
            this.onCancel()
          }
        })
        .onChange((value: number, mode: SliderChangeMode): void => {
          // Begin identifies a fresh native interaction even when it precedes Touch.Down.
          if (mode === SliderChangeMode.Begin) { this.cancelled = false; this.clickCommitted = false }
          if (this.cancelled) {
            return
          }
          const active = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving
          this.previewValue = value
          // Preserve preview through Touch.Up until native End has committed.
          this.dragging = active
          if (mode === SliderChangeMode.Begin) { this.onBegin() }
          if (active) { this.previewThumb(value, mode === SliderChangeMode.Begin) }
          this.onPreview(value, active)
          if (active) {
            this.clickCommitted = false
          } else if (mode === SliderChangeMode.Click) {
            this.clickCommitted = true
            this.onCommit(value)
            this.finishThumb()
          } else if (mode === SliderChangeMode.End) {
            if (!this.clickCommitted) { this.onCommit(value) }
            this.clickCommitted = false
            this.finishThumb()
          }
        })
      Circle().width(30).height(30).fill('#D7E9F8').stroke('#CCDEF0FF').strokeWidth(1)
        .translate({ x: this.isVertical ? 7 : this.railLength * this.thumbRatio - 15,
          y: this.isVertical ? this.railLength * (1 - this.thumbRatio) - 15 : 7 })
        .opacity(this.thumbVisible ? 1 : 0).hitTestBehavior(HitTestMode.None).id(this.label + '-thumb')
    }.width(this.isVertical ? 44 : this.railLength).height(this.isVertical ? this.railLength : 44)
  }
}

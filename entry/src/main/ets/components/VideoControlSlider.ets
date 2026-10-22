import { uiMaterial } from '@kit.ArkUI'

class VideoSliderThumb implements AttributeModifier<SliderAttribute> {
  private active: boolean

  constructor(active: boolean) { this.active = active }

  applyNormalAttribute(node: SliderAttribute): void {
    node.blockStyle(this.active ? { type: SliderBlockType.DEFAULT }
      : { type: SliderBlockType.SHAPE, shape: new Circle({ width: 30, height: 30 }).fill(Color.Transparent) })
      .blockColor(this.active ? '#D7E9F8' : Color.Transparent)
      .blockBorderColor(this.active ? '#CCDEF0FF' : Color.Transparent).blockBorderWidth(this.active ? 1 : 0)
    if (uiMaterial.isImmersiveMaterialSupported()) {
      node.systemMaterial(this.active ? new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN, materialColor: '#A6D7E9F8',
        interactive: true, applyShadow: true, lightEffect: { color: '#DAEDFF' }
      }) : uiMaterial.Material.empty)
    }
  }
}

/** HarmonyCast's capsule geometry, with local preview and the existing native Slider input. */
@ComponentV2
export struct VideoControlSlider {
  @Param value: number = 0
  @Param min: number = 0
  @Param max: number = 1
  @Param railLength: number = 1
  @Param bufferedValue: number = 0
  @Param isEnabled: boolean = true
  @Param label: string = ''
  @Event onPreview: (value: number, active: boolean) => void = () => {}
  @Event onCommit: (value: number) => void = () => {}
  @Local dragging: boolean = false
  private cancelled: boolean = false

  private ratio(value: number): number {
    return Math.max(0, Math.min(1, (value - this.min) / Math.max(0.001, this.max - this.min)))
  }

  build(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.Start }) {
        Rect().width('100%').height(8).radius(4).fill('#303237')
        Rect().width(this.railLength * this.ratio(this.bufferedValue)).height(8).radius(4).fill('#667078')
        Rect().width(this.railLength * this.ratio(this.value))
          .height(8).radius(4).fill('#DEE1E6')
      }.width(this.railLength).height(8).position({ x: 0, y: 18 }).hitTestBehavior(HitTestMode.None)
      Slider({ value: this.value, min: this.min, max: this.max,
        step: 1, style: SliderStyle.OutSet })
        .width(this.railLength + 30).height(44)
        .blockSize({ width: 30, height: 30 }).trackThickness(8)
        .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK_UP)
        .trackColor(Color.Transparent).selectedColor(Color.Transparent)
        .attributeModifier(new VideoSliderThumb(this.dragging))
        .position({ x: -15, y: 0 }).enabled(this.isEnabled)
        .id(this.label).accessibilityText(this.label)
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.cancelled = false
            this.dragging = true
          } else if (event.type === TouchType.Cancel) {
            this.cancelled = true
            this.dragging = false
            this.onPreview(this.value, false)
          }
        })
        .onChange((value: number, mode: SliderChangeMode): void => {
          if (this.cancelled) {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Moving) { return }
            this.cancelled = false
          }
          const active = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving
          // Preserve preview through Touch.Up until native End has committed.
          if (!active) { this.onCommit(value) }
          this.dragging = active
          this.onPreview(value, active)
        })
    }.width(this.railLength).height(44)
  }
}

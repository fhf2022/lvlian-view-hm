import { VideoControlSlider } from './VideoControlSlider'
import { uiMaterial } from '@kit.ArkUI'
import { videoControlGeometry, videoControlTime, videoRateAt, videoRatePosition } from '../ui/VideoControlLayout'

/** UI adapted from HarmonyCast ReceiverControls; playback and session ownership stay with LinkFiles. */
@ComponentV2
export struct VideoPlayerControls {
  @Param controlWidth: number = 344
  @Param positionMs: number = 0
  @Param durationMs: number = 0
  @Param bufferedMs: number = 0
  @Param rate: number = 1
  @Param playing: boolean = false
  @Param isEnabled: boolean = true
  @Param timelineReady: boolean = false
  @Param rotating: boolean = false
  @Param landscape: boolean = false
  @Param rateEnabled: boolean = true
  @Param ratePending: boolean = false
  @Param ratePanel: boolean = false
  @Event onToggle: () => void = () => {}
  @Event onSeek: (value: number) => void = () => {}
  @Event onSeeking: (active: boolean) => void = () => {}
  @Event onRate: (value: number) => void = () => {}
  @Event onRatePanel: (visible: boolean) => void = () => {}
  @Event onRotate: () => void = () => {}
  @Event onInteraction: (active: boolean) => void = () => {}
  @Local seeking: boolean = false
  @Local seekPreview: number = 0
  @Local rateDragging: boolean = false
  @Local ratePreview: number = 1

  private resetRate(): void {
    if (!this.isEnabled || !this.rateEnabled || this.ratePending) { return }
    this.rateDragging = false
    this.ratePreview = 1
    this.onRate(1)
  }

  private popupOptions(): CustomPopupOptions {
    return { builder: () => { this.RatePanel() }, placement: Placement.Top, enableArrow: false, targetSpace: 12,
      width: Math.min(256, this.controlWidth), radius: 20, popupColor: '#F01A1E24',
      backgroundBlurStyle: BlurStyle.NONE, systemMaterial: uiMaterial.Material.empty,
      autoCancel: true, focusable: true,
      onStateChange: (event: PopupStateChangeParam): void => {
        if (!event.isVisible) { this.rateDragging = false }
        this.onRatePanel(event.isVisible)
      } }
  }

  build(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play'))
          .fontSize(24).fontColor([Color.White]).draggable(false).hitTestBehavior(HitTestMode.None)
      }.width(28).height(40).draggable(false).focusable(true).accessibilityRole(AccessibilityRoleType.BUTTON)
        .opacity(this.isEnabled ? 1 : 0.4)
        .id('video-play-toggle').accessibilityText(this.playing ? '暂停视频' : '播放视频')
        .enabled(this.isEnabled).onClick(() => this.onToggle())
      Stack({ alignContent: Alignment.Center }) {
        Text(this.rate.toString() + '×').fontSize(14).minFontSize(11).maxFontSize(14).maxLines(1)
          .width('100%').textAlign(TextAlign.Center).fontColor('#E5EEF8')
          .draggable(false).hitTestBehavior(HitTestMode.None)
      }.width(32).height(40).position({ x: 28, y: 0 })
        .draggable(false).focusable(true).accessibilityRole(AccessibilityRoleType.BUTTON)
        .opacity(this.isEnabled && this.rateEnabled ? 1 : 0.4)
        .id('video-playback-rate').accessibilityText('调整播放倍速').enabled(this.isEnabled && this.rateEnabled)
        .onClick(() => {
          this.ratePreview = this.rate
          this.onRatePanel(!this.ratePanel)
        })
        .gesture(LongPressGesture({ repeat: false, duration: 500 })
          .onAction(() => { if (!this.ratePanel) { this.resetRate() } }))
        .accessibilityDescription('点击调整倍速，长按恢复 1 倍')
        .bindPopup(this.ratePanel, this.popupOptions())
      VideoControlSlider({ value: this.seeking ? this.seekPreview : (this.timelineReady ? this.positionMs : 0),
        max: Math.max(1, this.durationMs),
        bufferedValue: this.bufferedMs, railLength: videoControlGeometry(this.controlWidth).timelineWidth,
        isEnabled: this.isEnabled && this.timelineReady && this.durationMs > 0, label: 'video-progress-slider',
        onPreview: (value: number, active: boolean) => {
          this.seekPreview = value; this.seeking = active; this.onSeeking(active)
        },
        onCommit: (value: number) => this.onSeek(value) })
        .position({ x: videoControlGeometry(this.controlWidth).timelineX,
          y: videoControlGeometry(this.controlWidth).timelineY })
      Text(videoControlTime(this.seeking ? this.seekPreview : this.positionMs))
        .width(56).height(16).fontSize(11).fontColor('#DCE3F0').textAlign(TextAlign.Center)
        .draggable(false).hitTestBehavior(HitTestMode.None).id('video-current-time')
        .position({ x: videoControlGeometry(this.controlWidth).timelineX - 28,
          y: videoControlGeometry(this.controlWidth).timeY })
      Text(videoControlTime(this.durationMs))
        .width(56).height(16).fontSize(11).fontColor('#DCE3F0').textAlign(TextAlign.Center)
        .draggable(false).hitTestBehavior(HitTestMode.None).id('video-total-time')
        .position({ x: videoControlGeometry(this.controlWidth).timelineX +
          videoControlGeometry(this.controlWidth).timelineWidth - 28,
          y: videoControlGeometry(this.controlWidth).timeY })
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.video_rotate')).width(22).height(22).syncLoad(true)
          .draggable(false).hitTestBehavior(HitTestMode.None)
      }.width(32).height(40).draggable(false).focusable(true).accessibilityRole(AccessibilityRoleType.BUTTON)
        .opacity(this.isEnabled && !this.rotating ? 1 : 0.4)
        .id('video-rotate').enabled(this.isEnabled && !this.rotating)
        .accessibilityText(this.landscape ? '切换竖屏' : '切换横屏')
        .position({ x: videoControlGeometry(this.controlWidth).rotateX, y: 0 }).onClick(() => this.onRotate())
    }.width(this.controlWidth).height(videoControlGeometry(this.controlWidth).height).id('video-player-controls')
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) { this.onInteraction(true) }
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.onInteraction(false) }
      })
  }

  @Builder
  private RatePanel(): void {
    Column() {
      VideoControlSlider({ value: videoRatePosition(this.rateDragging || this.ratePending ? this.ratePreview : this.rate),
        min: -200, max: 200, railLength: Math.min(256, this.controlWidth) - 32,
        isEnabled: this.isEnabled && this.rateEnabled && !this.ratePending, label: 'video-rate-slider',
        onPreview: (value: number, active: boolean) => {
          this.ratePreview = videoRateAt(value); this.rateDragging = active
        }, onCommit: (value: number) => this.onRate(videoRateAt(value)) })
      Row() {
        Text('0.25×').fontSize(11).fontColor('#9DA6B2').layoutWeight(1).textAlign(TextAlign.Start)
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.playback_rate_reset')).width(16).height(16).syncLoad(true)
            .draggable(false).hitTestBehavior(HitTestMode.None)
        }.width(32).height(16)
          .responseRegion({ x: 0, y: 0, width: 32, height: 32 })
          .draggable(false).focusable(true).accessibilityRole(AccessibilityRoleType.BUTTON)
          .opacity(this.isEnabled && this.rateEnabled && !this.ratePending ? 1 : 0.4)
          .enabled(this.isEnabled && this.rateEnabled && !this.ratePending)
          .id('video-rate-reset').accessibilityText('恢复 1 倍').onClick(() => this.resetRate())
        Text('4×').fontSize(11).fontColor('#9DA6B2').layoutWeight(1).textAlign(TextAlign.End)
      }.width('100%').height(16)
        .responseRegion({ x: 0, y: 0, width: '100%', height: 32 })
    }.width(Math.min(256, this.controlWidth)).height(92).padding(16).id('video-rate-panel')
  }
}

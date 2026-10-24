import { GlassControlGeometry as Glass } from '../ui/GlassControlGeometry'
import { GlassMaterial } from '../ui/GlassMaterial'
import { uiMaterial } from '@kit.ArkUI'
import {
  DirectoryTimeline,
  DirectoryTimelinePolicy,
  TimelinePeriod
} from '../model/DirectoryTimeline'
import { ProximityLightReceiver } from './ProximityLightReceiver'
import { HapticFeedback } from '../core/haptic/HapticFeedback'

class TimelineMarker {
  id: string = ''
  time: number = 0
  y: number = 0
  label: string = ''
  kind: TimelinePeriod = 'day'
  opacity: number = 1
  length: number = 8
  hasImages: boolean = false
  isFocus: boolean = false
}

@Component
export struct FisheyeTimeline {
  @Prop timeline: DirectoryTimeline = new DirectoryTimeline()
  @Link focusTime: number
  @Prop widthVp: number = Glass.timelineWidth
  @Prop railWidthVp: number = Glass.timelineRailWidth
  @Prop heightVp: number = Glass.timelineMaxHeight
  /** Space owned by the TabBar renderer for native press deformation and shadow. */
  @Prop verticalEffectInsetVp: number = Glass.timelineEffectInset
  @Prop material: uiMaterial.ImmersiveMaterial = GlassMaterial.timeline()
  onScrubStart: () => void = () => {}
  onScrub: (time: number) => void = () => {}
  onScrubEnd: (time: number) => void = () => {}
  // 纯点击（没有拖动）时回调，交给外层做"展开/收起"。定位只由拖动触发。
  onTap: () => void = () => {}
  onSelect: (time: number, period: TimelinePeriod) => void = () => {}
  private touchActive: boolean = false
  private touchMoved: boolean = false
  private touchStartY: number = 0
  private touchStartFocus: number = 0
  private readonly moveThresholdVp: number = 5
  private readonly focusBubbleWidthVp: number = Glass.timelineBubbleWidth
  private readonly focusBubbleHeightVp: number = Glass.timelineBubbleHeight

  private clampFocus(value: number): number {
    const earliest = DirectoryTimelinePolicy.localDayStart(this.timeline.earliestTime)
    const latest = DirectoryTimelinePolicy.localDayStart(this.timeline.latestTime)
    return Math.max(earliest, Math.min(latest, value))
  }

  private addDays(value: number, amount: number): number {
    const date = new Date(value)
    date.setDate(date.getDate() + amount)
    return date.getTime()
  }

  private addMonths(value: number, amount: number): number {
    const date = new Date(value)
    return new Date(date.getFullYear(), date.getMonth() + amount, 1).getTime()
  }

  private addYears(value: number, amount: number): number {
    const date = new Date(value)
    return new Date(date.getFullYear() + amount, 0, 1).getTime()
  }

  private periodHasImages(value: number, kind: TimelinePeriod): boolean {
    let periodStart = DirectoryTimelinePolicy.localDayStart(value)
    let periodEnd = this.addDays(periodStart, 1)
    if (kind === 'month') {
      periodStart = this.addMonths(value, 0)
      periodEnd = this.addMonths(value, 1)
    } else if (kind === 'year') {
      const date = new Date(value)
      periodStart = new Date(date.getFullYear(), 0, 1).getTime()
      periodEnd = new Date(date.getFullYear() + 1, 0, 1).getTime()
    }
    let low = 0
    let high = this.timeline.buckets.length
    while (low < high) {
      const middle = Math.floor((low + high) / 2)
      if (this.timeline.buckets[middle].dayStart < periodStart) {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low < this.timeline.buckets.length &&
      this.timeline.buckets[low].dayStart < periodEnd
  }

  private marker(id: string, time: number, y: number, label: string,
    kind: TimelinePeriod, opacity: number, length: number, isFocus: boolean = false): TimelineMarker {
    const marker = new TimelineMarker()
    marker.id = id
    marker.time = time
    marker.y = y
    marker.label = label
    marker.kind = kind
    marker.opacity = opacity
    marker.length = length
    marker.hasImages = this.periodHasImages(time, kind)
    marker.isFocus = isFocus
    return marker
  }

  private focusLabel(): string {
    const date = new Date(this.focusTime)
    return (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日'
  }

  private markers(): TimelineMarker[] {
    const result: TimelineMarker[] = []
    const center = this.heightVp / 2
    const focusDay = DirectoryTimelinePolicy.localDayStart(this.focusTime)
    const nextDay = this.addDays(focusDay, 1)
    const fraction = nextDay > focusDay ? (this.focusTime - focusDay) / (nextDay - focusDay) : 0
    // Earlier dates stay below the focus point. Moving the rail upward brings
    // those dates into focus, so the content follows the finger and time moves
    // toward the past regardless of the file list's sort direction.
    const direction = -1
    const frameKey = Math.floor(this.focusTime / (15 * 60 * 1000)).toString()
    const dayPitch = Math.max(24, Math.min(34, this.heightVp / 16))
    for (let offset = -3; offset <= 3; offset++) {
      const time = this.addDays(focusDay, offset)
      const date = new Date(time)
      const label = offset === 0 ? (date.getMonth() + 1).toString() + '/' +
        date.getDate().toString() : (Math.abs(offset) === 1 ? date.getDate().toString() : '')
      const temporalOffset = offset - fraction
      result.push(this.marker('d' + offset.toString() + ':' + frameKey, time,
        center + temporalOffset * dayPitch * direction, label, 'day',
        offset === 0 ? 1 : 0.82 - Math.abs(offset) * 0.08, offset === 0 ? 17 : 11,
        offset === 0))
    }

    const dayExtent = dayPitch * 3
    const monthBase = Math.max(dayExtent + 22, this.heightVp * 0.27)
    const monthStep = Math.max(20, this.heightVp * 0.045)
    for (let offset = 1; offset <= 3; offset++) {
      const before = this.addMonths(focusDay, -offset)
      const after = this.addMonths(focusDay, offset)
      const distance = monthBase + (offset - 1) * monthStep
      result.push(this.marker('mb' + offset.toString() + ':' + frameKey, before,
        center - distance * direction, offset <= 2
          ? (new Date(before).getMonth() + 1).toString() + '月' : '',
        'month', 0.62 - offset * 0.07, 9))
      result.push(this.marker('ma' + offset.toString() + ':' + frameKey, after,
        center + distance * direction, offset <= 2
          ? (new Date(after).getMonth() + 1).toString() + '月' : '',
        'month', 0.62 - offset * 0.07, 9))
    }

    const yearBase = Math.max(monthBase + monthStep * 2 + 20, this.heightVp * 0.43)
    const yearStep = Math.max(18, this.heightVp * 0.035)
    for (let offset = 1; offset <= 2; offset++) {
      const before = this.addYears(focusDay, -offset)
      const after = this.addYears(focusDay, offset)
      const distance = Math.min(this.heightVp / 2 - 12, yearBase + (offset - 1) * yearStep)
      result.push(this.marker('yb' + offset.toString() + ':' + frameKey, before,
        center - distance * direction, offset === 1
          ? new Date(before).getFullYear().toString() : '', 'year', 0.36, 6))
      result.push(this.marker('ya' + offset.toString() + ':' + frameKey, after,
        center + distance * direction, offset === 1
          ? new Date(after).getFullYear().toString() : '', 'year', 0.36, 6))
    }
    return result
  }

  private selectNearest(y: number): void {
    const railY = y - this.verticalEffectInsetVp
    const markers = this.markers()
    let selected: TimelineMarker | null = null
    let distance = Number.MAX_SAFE_INTEGER
    for (const marker of markers) {
      const markerDistance = Math.abs(marker.y - railY)
      if (markerDistance < distance) {
        selected = marker
        distance = markerDistance
      }
    }
    if (selected !== null) {
      this.onSelect(selected.time, selected.kind)
    }
  }

  /**
   * 点击位置是否落在「凸出来的日期」（焦点标记）上。
   *
   * 交互约定：点这个放大的日期 = 展开/收起；点时间轴的其它位置 = 跳到该时间。
   * 早先的实现把「没拖动的点击」一律当成展开/收起，定位能力就没了。
   */
  private hitFocusMarker(y: number): boolean {
    const railY = y - this.verticalEffectInsetVp
    for (const marker of this.markers()) {
      if (!marker.isFocus) {
        continue
      }
      // 阈值取焦点标记字号的一半再留些余量，保证手指点得中。
      if (Math.abs(marker.y - railY) <= marker.length * 0.5 + 10) {
        return true
      }
    }
    return false
  }

  private handleTouch(event: TouchEvent): void {
    const points = event.touches.length > 0 ? event.touches : event.changedTouches
    const point = points.length > 0 ? points[0] : null
    if (event.type === TouchType.Down && point !== null) {
      this.touchActive = true
      this.touchMoved = false
      this.touchStartY = point.y
      this.touchStartFocus = this.focusTime
      this.onScrubStart()
      return
    }
    if (event.type === TouchType.Move && this.touchActive && point !== null) {
      const delta = point.y - this.touchStartY
      // A real device keeps reporting tiny Move samples even during a tap.
      // Do not turn those samples into synchronous long-list jumps; the tap
      // is resolved once on Up by selectNearest().
      if (!this.touchMoved && Math.abs(delta) <= this.moveThresholdVp) {
        return
      }
      this.touchMoved = true
      const previousDay = Math.floor(this.focusTime / DirectoryTimelinePolicy.DAY_MS)
      this.focusTime = this.clampFocus(this.touchStartFocus +
        delta / 38 * DirectoryTimelinePolicy.DAY_MS)
      // One tick per day crossed. The list itself only moves in coarse jumps
      // while scrubbing, so this is the only feedback that says how far the
      // finger has travelled — but a fling crosses many days, which is why the
      // cue is throttled in HapticFeedback rather than here.
      if (Math.floor(this.focusTime / DirectoryTimelinePolicy.DAY_MS) !== previousDay) {
        HapticFeedback.tick()
      }
      this.onScrub(this.focusTime)
      return
    }
    if ((event.type === TouchType.Up || event.type === TouchType.Cancel) && this.touchActive) {
      const y = point === null ? this.touchStartY : point.y
      this.touchActive = false
      if (this.touchMoved) {
        const snapped = DirectoryTimelinePolicy.closestDay(this.timeline, this.focusTime)
        this.focusTime = this.clampFocus(snapped)
        this.onScrubEnd(this.focusTime)
      } else {
        // 没有拖动的「点击」分两种：
        //   - 点在「凸出来的日期」（isFocus 焦点标记）上 → 展开/收起；
        //   - 点在时间轴的其它位置（月/年刻度、空白处）→ 跳到该时间。
        // 早先一律调 onTap()，定位能力因此消失了。
        if (this.hitFocusMarker(y)) {
          this.onTap()
        } else {
          this.selectNearest(y)
        }
      }
      this.touchMoved = false
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Keep the material surface unclipped so its outer shadow can fade
      // naturally. Clip only the marker content inside a same-size layer.
      Stack() {
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width(1)
            .height(Math.max(0, this.heightVp - 28))
            .backgroundColor('#24FFFFFF')
            .position({ x: 8, y: 14 })

          ForEach(this.markers(), (marker: TimelineMarker) => {
            if (!marker.isFocus) {
              Row({ space: 3 }) {
                Row()
                  .width(marker.length)
                  .height(marker.hasImages ? 3 : 1)
                  .borderRadius(2)
                  .backgroundColor(marker.hasImages ? '#D92E6BFF' :
                    $r('sys.color.icon_secondary'))
                Text(marker.label)
                  .fontSize(marker.kind === 'day' ? 10 : 9)
                  .fontWeight(FontWeight.Regular)
                  .fontColor($r('sys.color.font_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width(Math.max(30, this.railWidthVp - 8))
              .height(18)
              .alignItems(VerticalAlign.Center)
              .opacity(marker.opacity)
              .position({ x: 4, y: marker.y - 9 })
            }
          }, (marker: TimelineMarker): string => marker.id)

          ProximityLightReceiver()
            .width('100%')
            .height('100%')
            .hitTestBehavior(HitTestMode.None)
        }
        .width(this.railWidthVp)
        .height('100%')
        .borderRadius(this.railWidthVp / 2)
        .clip(true)
      }
      .width(this.railWidthVp)
      .height(this.heightVp)
      .borderRadius(this.railWidthVp / 2)
      .systemMaterial(this.material)
      .shadow({
        radius: 18,
        color: '#20000000',
        offsetX: 0,
        offsetY: 2
      })
      .position({
        x: Math.max(0, this.widthVp - this.railWidthVp),
        y: this.verticalEffectInsetVp
      })

      Stack({ alignContent: Alignment.Center }) {
        Text(this.focusLabel())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
      }
      .width(this.focusBubbleWidthVp)
      .height(this.focusBubbleHeightVp)
      .borderRadius(this.focusBubbleHeightVp / 2)
      // This surface overlaps the rail, so it must not start a second
      // material pass. A themed translucent fill keeps the selected date
      // distinct without cutting the rail's continuous shadow.
      .backgroundColor($r('app.color.card_glass_bg'))
      .border({ width: 1, color: '#70FFFFFF' })
      .position({
        x: Math.max(0, this.widthVp - this.focusBubbleWidthVp),
        y: this.verticalEffectInsetVp + this.heightVp / 2 - this.focusBubbleHeightVp / 2
      })
      .hitTestBehavior(HitTestMode.None)
    }
    .width(this.widthVp)
    .height(this.heightVp + this.verticalEffectInsetVp * 2)
    .clip(false)
    .monopolizeEvents(true)
    .hitTestBehavior(HitTestMode.Default)
    .onTouch((event: TouchEvent): void => this.handleTouch(event))
    .accessibilityText('图片时间轴')
  }
}

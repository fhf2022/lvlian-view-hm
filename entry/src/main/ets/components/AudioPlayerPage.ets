/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *     http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Adapted 2026-10-20 for LinkFiles from RzdPai/RzdMusic @ 5ec7e494:
 * PlaybackPage, MusicPlayInfoBlock, ControlAreaComponent and TopAreaComponent.
 * Retains the cover/meta/progress/transport/auxiliary layout; all business
 * state is supplied by LinkFiles. Favorites, comments and mini bar removed.
 */
import { uiObserver } from '@kit.ArkUI'
import { AVCastPicker } from '@kit.AVSessionKit'
import { AudioLyricLine, AudioPlayerPolicy, AudioPlayMode } from '../media/AudioPlayerPolicy'
import { HeaderStyle } from '../ui/HeaderStyle'

/** Immutable lyric rows are mounted only near the visible part of the list. */
class AudioLyricSource implements IDataSource {
  private values: AudioLyricLine[] = []
  private listeners: DataChangeListener[] = []
  totalCount(): number { return this.values.length }
  getData(index: number): AudioLyricLine { return this.values[index] }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) { this.listeners.push(listener) }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener)
  }
  replace(values: AudioLyricLine[]): void {
    this.values = values
    this.listeners.forEach((listener: DataChangeListener): void => listener.onDataReloaded())
  }
}

@ComponentV2
export struct AudioPlayerPage {
  @Env(SystemProperties.BREAK_POINT) breakpoint: uiObserver.WindowSizeLayoutBreakpointInfo
  @Param cover: ResourceStr = ''
  @Param title: string = ''
  @Param artist: string = ''
  @Param format: string = ''
  @Param playing: boolean = false
  @Param opening: boolean = false
  @Param coverScale: number = 0
  @Param busy: boolean = false
  @Param positionMs: number = 0
  @Param durationMs: number = 0
  @Param playMode: AudioPlayMode = 'order'
  @Param lyrics: AudioLyricLine[] = []
  @Param safeTop: number = 0
  @Param safeBottom: number = 0
  @Param dark: boolean = false
  @Param coverHidden: boolean = false
  @Event onBack: () => void = () => {}
  @Event onShare: () => void = () => {}
  @Event onToggle: () => void = () => {}
  @Event onPrevious: () => void = () => {}
  @Event onNext: () => void = () => {}
  @Event onMode: () => void = () => {}
  @Event onQueue: () => void = () => {}
  @Event onDownload: () => void = () => {}
  @Event onDetails: () => void = () => {}
  @Event onSeek: (value: number) => void = () => {}
  @Event onCoverArea: (area: Area) => void = () => {}
  @Event onCoverVisibility: (ratio: number) => void = () => {}
  @BuilderParam backButton: () => void = this.DefaultBack
  @Local lyricPage: number = 0
  @Local seeking: boolean = false
  @Local seekValue: number = 0
  @Local viewportWidth: number = 0
  @Local viewportHeight: number = 0
  @Local activeLyricIndex: number = -1
  private lyricScroller: Scroller = new Scroller()
  private lyricSource: AudioLyricSource = new AudioLyricSource()
  private lastLyricIndex: number = -1
  private seekCancelled: boolean = false
  private seekClickCommitted: boolean = false

  aboutToAppear(): void { this.refreshLyrics() }

  @Monitor('lyrics')
  private refreshLyrics(): void {
    this.lyricSource.replace(this.lyrics)
    this.lastLyricIndex = -1
    this.updateLyricPosition()
  }

  private compact(): boolean {
    return this.breakpoint.widthBreakpoint === WidthBreakpoint.WIDTH_SM &&
      this.breakpoint.heightBreakpoint === HeightBreakpoint.HEIGHT_MD
  }

  private wide(): boolean {
    if (this.viewportWidth > this.viewportHeight && this.viewportHeight > 0 &&
      this.breakpoint.widthBreakpoint !== WidthBreakpoint.WIDTH_SM) { return true }
    return this.breakpoint.widthBreakpoint !== WidthBreakpoint.WIDTH_SM &&
      !(this.breakpoint.widthBreakpoint === WidthBreakpoint.WIDTH_MD &&
        this.breakpoint.heightBreakpoint === HeightBreakpoint.HEIGHT_SM)
  }

  private time(value: number): string {
    const seconds = Math.floor(Math.max(0, value) / 1000)
    return Math.floor(seconds / 60).toString() + ':' + (seconds % 60).toString().padStart(2, '0')
  }

  private shortWide(): boolean { return this.wide() && this.viewportHeight > 0 && this.viewportHeight < 600 }

  private playSize(): number { return this.shortWide() ? 56 : (this.wide() ? 88 : 72) }

  private displayCoverScale(): number { return this.coverScale > 0 ? this.coverScale : (this.playing ? 1.05 : 0.95) }

  private foreground(): Resource { return $r('sys.color.font_primary') }
  private secondary(): Resource { return $r('sys.color.font_secondary') }

  @Monitor('positionMs', 'lyricPage')
  private updateLyricPosition(): void {
    const index = AudioPlayerPolicy.lyricIndex(this.lyrics, this.positionMs)
    this.activeLyricIndex = index
    if (index < 0 || index === this.lastLyricIndex || (!this.wide() && this.lyricPage !== 1)) { return }
    this.lastLyricIndex = index
    try { this.lyricScroller.scrollToIndex(index, true, ScrollAlign.CENTER) } catch (_) {}
  }

  @Builder
  DefaultBack(): void {
    Button() {
      SymbolGlyph($r('sys.symbol.chevron_backward')).fontSize(HeaderStyle.iconSize)
        .fontColor([$r('sys.color.icon_primary')])
    }
    .width(HeaderStyle.controlHeight).height(HeaderStyle.controlHeight)
    .type(ButtonType.Circle).backgroundColor(Color.Transparent).onClick(() => this.onBack())
    .stateEffect(false).hoverEffect(HoverEffect.None).draggable(false)
    .accessibilityText('返回')
  }

  @Builder
  private Glyph(symbol: Resource, label: string, action: () => void, size: number = 24): void {
    Button() {
      SymbolGlyph(symbol).fontSize(size).fontWeight(FontWeight.Regular).fontColor([this.foreground()])
        .draggable(false).hitTestBehavior(HitTestMode.None)
    }
    .type(ButtonType.Normal).width(40).height(40).borderRadius(20)
    .stateEffect(false).hoverEffect(HoverEffect.None).draggable(false)
    .backgroundColor(Color.Transparent).accessibilityText(label).enabled(!this.busy)
    .onClick(action).accessibilityLevel('yes').id('audio-control-' + label)
  }

  @Builder
  private Header(): void {
    Row() {
      this.backButton()
      Blank()
      this.Glyph($r('sys.symbol.share'), '分享', () => this.onShare())
    }
    .width('100%').height(56).padding({ left: HeaderStyle.sideInset, right: HeaderStyle.sideInset })
    .position({ x: 0, y: this.safeTop }).zIndex(2)
  }

  @Builder
  private Metadata(): void {
    Column() {
      Text(this.title).fontSize(this.wide() && !this.shortWide() ? 24 : 20).fontWeight(FontWeight.Bold)
        .draggable(false)
        .fontColor(this.foreground()).opacity(0.86).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').id('audio-track-title')
      Text(this.artist).fontSize(this.wide() && !this.shortWide() ? 22 : 14).fontWeight(FontWeight.Regular)
        .draggable(false)
        .fontColor(this.secondary()).margin({ top: 2 }).width('100%').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).id('audio-track-artist')
    }
    .width('100%')
  }

  @Builder
  private CoverInfo(): void {
    Column() {
      Stack() {
        Image(this.cover).constraintSize({ maxWidth: '100%', maxHeight: '100%' }).aspectRatio(1)
          .draggable(false)
          .objectFit(ImageFit.Cover).borderRadius(16).clip(true)
          .scale({ x: this.displayCoverScale(), y: this.displayCoverScale() })
          .animation({ duration: 280, curve: Curve.EaseOut })
          .opacity(this.coverHidden ? 0 : 1).id('audio-album-cover')
          .onAreaChange((_old: Area, area: Area) => this.onCoverArea(area))
          // Account for the playing scale and the real ancestor clipping.
          // The legacy calculation treats overflow in unclipped parents as
          // invisible, incorrectly rejecting the 1.05x cover on return.
          .onVisibleAreaChange([0, 0.999],
            (_visible: boolean, ratio: number) => this.onCoverVisibility(ratio), true)
      }
      .width('100%').layoutWeight(1)
      Column() { this.Metadata() }.width('100%').margin({ top: this.shortWide() ? 12 : 24 })
    }
    .width('100%').height('100%')
  }

  @Builder
  private LyricContent(): void {
    if (this.lyrics.length === 0) {
      Column() {
        Text('暂无歌词').fontSize(20).fontColor(this.secondary()).draggable(false)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    } else {
      List({ space: 24, scroller: this.lyricScroller }) {
        LazyForEach(this.lyricSource, (line: AudioLyricLine, index: number) => {
          ListItem() {
            Text(line.text).fontSize(26).fontWeight(FontWeight.Bold).width('100%')
              .draggable(false)
              .fontColor(this.foreground())
              .opacity(index === this.activeLyricIndex ? 1 : 0.42)
              .padding({ top: 8, bottom: 8 }).onClick(() => this.onSeek(line.timeMs))
          }
        }, (line: AudioLyricLine, index: number) => index.toString() + ':' + line.timeMs.toString())
      }
      .width('100%').height('100%').scrollBar(BarState.Off)
      .contentStartOffset(40).contentEndOffset(80)
    }
  }

  @Builder
  private Progress(): void {
    Column() {
      Slider({ min: 0, max: Math.max(1, this.durationMs), step: 1,
        value: this.seeking ? this.seekValue : Math.min(this.positionMs, this.durationMs) })
        .blockColor(this.foreground()).selectedColor(this.foreground()).trackColor(this.dark ? '#33FFFFFF' : '#33172033')
        .blockSize({ width: 1, height: 1 }).height(16).margin({ left: -4, right: -4 })
        .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK_UP)
        .enabled(!this.busy && this.durationMs > 0).hitTestBehavior(HitTestMode.Block)
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.seekCancelled = false; this.seekClickCommitted = false
          } else if (event.type === TouchType.Cancel) {
            this.seekCancelled = true; this.seeking = false
          }
        })
        .onChange((value: number, mode: SliderChangeMode) => {
          if (this.seekCancelled) { return }
          this.seekValue = value
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.seeking = true; this.seekClickCommitted = false
          } else if (mode === SliderChangeMode.Click) {
            this.seeking = false; this.seekClickCommitted = true; this.onSeek(value)
          } else if (mode === SliderChangeMode.End) {
            this.seeking = false
            if (!this.seekClickCommitted) { this.onSeek(value) }
            this.seekClickCommitted = false
          }
        }).id('audio-progress-slider')
      Row() {
        Text(this.time(this.seeking ? this.seekValue : this.positionMs)).fontSize(10).fontColor(this.secondary()).lineHeight(14)
          .draggable(false)
        Blank()
        Text(this.format).fontSize(11).fontColor(this.secondary()).lineHeight(16)
          .draggable(false)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(10)
          .backgroundColor(this.dark ? '#1FFFFFFF' : '#0F172033')
        Blank()
        Text(this.time(this.durationMs)).fontSize(10).fontColor(this.secondary()).lineHeight(14)
          .draggable(false)
      }.width('100%').justifyContent(FlexAlign.SpaceBetween)
    }
    .margin({ top: this.shortWide() ? 8 : (this.compact() ? 0 : 24),
      bottom: this.shortWide() || this.compact() ? 8 : 16 })
  }

  @Builder
  private TransportImage(source: Resource, label: string, size: number, action: () => void): void {
    Button() {
      Image(source).width(size).height(size).objectFit(ImageFit.Contain)
        .fillColor(this.foreground()).draggable(false).hitTestBehavior(HitTestMode.None)
    }
    .width(size + 8).height(Math.max(44, size)).type(ButtonType.Normal)
    .stateEffect(false).hoverEffect(HoverEffect.None).draggable(false)
    .backgroundColor(Color.Transparent).accessibilityText(label).enabled(!this.busy).onClick(action)
    .accessibilityLevel('yes').id('audio-control-' + label)
  }

  // State-dependent resources stay in parameterless builders. Passing their
  // current value through a value-parameter builder freezes the first SVG on
  // some ArkUI runtimes even though playback itself has already changed.
  @Builder
  private PlayControl(): void {
    Button() {
      if (this.busy && this.durationMs <= 0) {
        LoadingProgress().width(40).height(40).color(this.foreground()).accessibilityText('正在准备音频')
      } else {
        Image(this.playing ? $r('app.media.audio_pause') : $r('app.media.audio_play'))
          .width(this.playSize()).height(this.playSize())
          .objectFit(ImageFit.Contain).fillColor(this.foreground())
          // Both SVGs are tiny bundled assets. Commit the new raster in the
          // same frame instead of briefly clearing the previous async source.
          .syncLoad(true)
          .draggable(false).hitTestBehavior(HitTestMode.None)
      }
    }
    .width(this.playSize() + 8).height(this.playSize()).type(ButtonType.Normal)
    .stateEffect(false).hoverEffect(HoverEffect.None).draggable(false)
    .backgroundColor(Color.Transparent).enabled(!this.busy).onClick(() => this.onToggle())
    .accessibilityText(this.playing ? '暂停' : '播放').accessibilityLevel('yes').id('audio-play-toggle')
  }

  @Builder
  private ModeControl(): void {
    Button() {
      SymbolGlyph(this.playMode === 'shuffle' ? $r('sys.symbol.shuffle') :
        (this.playMode === 'repeat' ? $r('sys.symbol.repeat_1') : $r('sys.symbol.repeat')))
        .fontSize(24).fontWeight(FontWeight.Regular).fontColor([this.foreground()])
        .draggable(false).hitTestBehavior(HitTestMode.None)
    }
    .type(ButtonType.Normal).width(40).height(40).borderRadius(20)
    .stateEffect(false).hoverEffect(HoverEffect.None).draggable(false)
    .backgroundColor(Color.Transparent).enabled(!this.busy).onClick(() => this.onMode())
    .accessibilityText(this.playMode === 'order' ? '顺序循环' :
      (this.playMode === 'repeat' ? '单曲循环' : '随机播放')).accessibilityLevel('yes').id('audio-play-mode')
  }

  @Builder
  private Controls(): void {
    Column() {
      this.Progress()
      Row() {
        this.ModeControl()
        this.TransportImage($r('app.media.audio_previous'), '上一首', this.shortWide() ? 28 : (this.wide() ? 36 : 32), () => this.onPrevious())
        this.PlayControl()
        this.TransportImage($r('app.media.audio_next'), '下一首', this.shortWide() ? 28 : (this.wide() ? 36 : 32), () => this.onNext())
        this.Glyph($r('sys.symbol.music_note_list'), '播放列表', () => this.onQueue())
      }.width('100%').justifyContent(FlexAlign.SpaceBetween)
      Row() {
        AVCastPicker({ normalColor: this.dark ? '#99FFFFFF' : '#99172033',
          activeColor: '#2E6BFF', customPicker: () => { this.CastIcon() } })
          .width(40).height(40)
          .draggable(false).hoverEffect(HoverEffect.None).id('audio-control-音频输出设备')
        this.Glyph($r('sys.symbol.arrow_down_circle'), '下载', () => this.onDownload(), 22)
        this.Glyph($r('sys.symbol.info_circle'), '详情', () => this.onDetails(), 22)
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).padding({ top: this.shortWide() ? 12 : 24 })
    }
    .width('100%').borderRadius(16).padding({ top: 8, left: 4, right: 4 })
  }

  @Builder
  private CastIcon(): void {
    SymbolGlyph($r('sys.symbol.shareplay')).fontSize(22).fontWeight(FontWeight.Regular)
      .fontColor([this.foreground()]).accessibilityText('音频输出设备')
      .draggable(false)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column().width('100%').height('100%').backgroundColor(this.dark ? '#1C1C1E' : '#F1F3F5')
      Image(this.cover).width('100%').height('100%').objectFit(ImageFit.Cover)
        .draggable(false)
        .sourceSize({ width: 128, height: 128 })
        .blur(80).opacity(this.dark ? 0.35 : 0.15).hitTestBehavior(HitTestMode.None)
      if (this.wide()) {
        Row({ space: 56 }) {
          Column() {
            Column() { this.CoverInfo() }.width('100%').layoutWeight(1)
            this.Controls()
          }.layoutWeight(1).height('100%')
          Column() { this.LyricContent() }.layoutWeight(1).height('100%')
        }
        .padding({ left: 56, right: 56, top: this.safeTop + (this.shortWide() ? 56 : 80),
          bottom: this.safeBottom + (this.shortWide() ? 20 : 48) })
        .width('100%').height('100%')
      } else {
        Column() {
          Swiper() {
            Column() {
              if (this.compact()) {
                Column() { Blank(); this.Metadata() }
                  .padding({ left: 28, right: 28, bottom: 20 }).width('100%').height('100%')
                  .onAppear(() => this.onCoverVisibility(0))
              } else {
                Column() { this.CoverInfo() }
                  .padding({ left: 24, right: 24, top: 72, bottom: 20 }).width('100%').height('100%')
              }
            }.width('100%').height('100%')
            Column() { this.LyricContent() }.padding({ left: 24, right: 24, top: 72 })
              .width('100%').height('100%')
          }
          .loop(false).indicator(false).layoutWeight(1).enabled(!this.opening)
          .onChange((index: number) => { this.lyricPage = index })
          Column() { this.Controls() }.width('100%').padding({ left: 24, right: 24, bottom: 10 })
        }
        .width('100%').height('100%').padding({ top: this.safeTop, bottom: this.safeBottom })
      }
      this.Header()
    }
    .width('100%').height('100%').clip(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_old: Area, area: Area) => {
      this.viewportWidth = Number(area.width); this.viewportHeight = Number(area.height)
    })
    .id('audio-playback-page')
  }
}

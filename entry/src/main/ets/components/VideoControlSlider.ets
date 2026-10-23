import { PlaybackSlider } from '../shared/PlaybackSlider'

/** LinkFiles callback adapter; the shared component owns input, paint and motion. */
@ComponentV2
export struct VideoControlSlider {
  @Param value: number = 0
  @Param min: number = 0
  @Param max: number = 1
  @Param railLength: number = 1
  @Param bufferedValue: number | undefined = undefined
  @Param isEnabled: boolean = true
  @Param label: string = ''
  @Event onPreview: (value: number, active: boolean) => void = () => {}
  @Event onCommit: (value: number) => void = () => {}

  build(): void {
    PlaybackSlider({ value: this.value, min: this.min, max: this.max, railLength: this.railLength,
      bufferedValue: this.bufferedValue, isEnabled: this.isEnabled, label: this.label,
      onPreview: (value: number, active: boolean): void => this.onPreview(value, active),
      onCommit: (value: number): void => this.onCommit(value) })
  }
}

/** Logical sizes only. Native material hosts must also reserve their effect space. */
export class GlassControlGeometry {
  static readonly barHeight: number = 56
  static readonly barWidth: number = 328
  static readonly iconSize: number = 24
  static readonly labelSize: number = 12
  static readonly itemGap: number = 2
  static readonly contentPadding: number = 8
  static readonly windowInset: number = 16
  static readonly barEffectTop: number = 20
  static readonly nativeBarOffset: number = 40
  static readonly barHostHeight: number = GlassControlGeometry.barHeight +
    GlassControlGeometry.barEffectTop + GlassControlGeometry.nativeBarOffset * 2
  static readonly barSlotHeight: number = GlassControlGeometry.barHeight +
    GlassControlGeometry.barEffectTop + GlassControlGeometry.nativeBarOffset
  static readonly sortWidth: number = 140
  static readonly toolsInset: number = 16
  static readonly timelineWidth: number = 68
  static readonly timelineRailWidth: number = 42
  static readonly timelineEffectInset: number = 16
  static readonly timelineMaxHeight: number = 520
  static readonly timelineMinHeight: number = 120
  static readonly timelineBubbleWidth: number = 58
  static readonly timelineBubbleHeight: number = 30
  static readonly timelineGap: number = 8
  static readonly timelinePeek: number = 28
  static readonly menuWidth: number = 228
  static readonly menuRadius: number = 24
  static readonly menuPadding: number = 10
  static readonly menuVerticalPadding: number = 8
  static readonly menuRowHeight: number = 48
  static readonly importWidth: number = 180
  static readonly importRowHeight: number = 48
  static readonly importPadding: number = 8
  static readonly importHeight: number = 208

  static width(windowWidth: number): number {
    return Math.max(0, Math.min(GlassControlGeometry.barWidth,
      windowWidth - GlassControlGeometry.windowInset * 2))
  }

  static timelineHeight(availableHeight: number): number {
    return availableHeight < GlassControlGeometry.timelineMinHeight ? 0 :
      Math.min(GlassControlGeometry.timelineMaxHeight, availableHeight)
  }

  static timelineTop(contentTop: number, contentBottom: number): number {
    const available = Math.max(0, contentBottom - contentTop -
      GlassControlGeometry.timelineGap * 2 - GlassControlGeometry.timelineEffectInset * 2)
    const railHeight = GlassControlGeometry.timelineHeight(available)
    // Centre the complete native renderer, including its deformation space,
    // between the file header and the bottom controls. The 520vp cap must not
    // leave all of a tall window's unused space below the rail.
    return contentTop + GlassControlGeometry.timelineGap + Math.max(0, (available - railHeight) / 2)
  }
}

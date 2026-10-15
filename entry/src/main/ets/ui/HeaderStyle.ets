/** Shared geometry for app-owned headers; the system safe area is added by each host. */
export class HeaderStyle {
  static readonly sideInset: number = 16
  static readonly gap: number = 8
  static readonly controlHeight: number = 40
  static readonly iconSize: number = 24
  static readonly titleSize: number = 20
  static readonly actionSize: number = 15
  static readonly rowHeight: number = 56
  static readonly topPadding: number = 8
  // Native sheet close controls start 16 vp below the sheet's top edge.
  static readonly sheetTopPadding: number = 16
  static readonly bottomPadding: number = 30
  static readonly overlayHeight: number = 94
  static readonly searchOverlayHeight: number = 136
  static readonly contentTopInset: number = 76
}

import { HeaderStyle } from './HeaderStyle'

/** Geometry shared by destination selection, native album selection and upload confirmation. */
export class TaskPanelStyle {
  static readonly inset: number = HeaderStyle.sideInset
  static readonly headerHeight: number = HeaderStyle.rowHeight
  static readonly corner: number = 32
  static readonly sectionCorner: number = 20
  static readonly sectionGap: number = 12
  static readonly actionHeight: number = 48
  static readonly footerPadding: number = 16
  static readonly compactChromeHeight: number = HeaderStyle.rowHeight + 48 + 32
}

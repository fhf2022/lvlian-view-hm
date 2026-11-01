import { HeaderStyle } from './HeaderStyle'
import { curves } from '@kit.ArkUI'

/** Geometry shared by destination selection, native album selection and upload confirmation. */
export class TaskPanelStyle {
  static readonly inset: number = HeaderStyle.sideInset
  static readonly headerHeight: number = HeaderStyle.rowHeight
  static readonly corner: number = 32
  static readonly sectionGap: number = 12
  static readonly actionHeight: number = 48
  static readonly footerPadding: number = 16
  static readonly edge: number = 16
  static readonly minimumBodyHeight: number = 280

  // Content never participates in these dimensions. A short window takes
  // precedence over the preferred minimum; the body then scrolls as a whole.
  static width(windowWidth: number, ratio: number = 0.9, compact: boolean = false): number {
    const width = Number.isFinite(windowWidth) ? Math.max(0, windowWidth) : 0
    return Math.min(compact ? 420 : 720, width * ratio, Math.max(0, width - TaskPanelStyle.edge * 2))
  }

  static dialogWidth(windowWidth: number): number {
    return TaskPanelStyle.width(windowWidth, 0.84, true)
  }

  static height(windowHeight: number, safeTop: number, safeBottom: number, compact: boolean = false): number {
    const height = Number.isFinite(windowHeight) ? Math.max(0, windowHeight) : 0
    const top = Number.isFinite(safeTop) ? Math.max(0, safeTop) : 0
    const bottom = Number.isFinite(safeBottom) ? Math.max(0, safeBottom) : 0
    return Math.min(Math.max(0, height - top - bottom - TaskPanelStyle.edge * 2),
      compact ? 380 : Math.max(420, height * 0.7))
  }

  static transition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ y: 40 }).combine(TransitionEffect.opacity(0))
        .combine(TransitionEffect.scale({ x: 0.97, y: 0.97 }))
        .animation({ duration: 340, curve: curves.interpolatingSpring(0, 1, 320, 30) }),
      TransitionEffect.translate({ y: 10 }).combine(TransitionEffect.opacity(0))
        .combine(TransitionEffect.scale({ x: 0.97, y: 0.97 }))
        .animation({ duration: 180, curve: Curve.EaseOut }))
  }
}

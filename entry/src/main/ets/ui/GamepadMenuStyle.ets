/** A quiet row highlight; the existing popup continues to own the glass material. */
export class GamepadMenuStyle {
  static ink(selected: boolean, regular: ResourceColor, danger: boolean = false): ResourceColor {
    return selected && !danger ? $r('sys.color.font_emphasize') : regular
  }

  static background(selected: boolean, dark: boolean, danger: boolean = false): ResourceColor {
    if (!selected) { return Color.Transparent }
    if (danger) { return '#12D34D5C' }
    return dark ? '#14FFFFFF' : '#0D243247'
  }
}

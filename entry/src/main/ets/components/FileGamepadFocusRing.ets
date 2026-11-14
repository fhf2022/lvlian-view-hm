/** One thumbnail-sized controller marker, shared by grid and waterfall cells. */
@Component
export struct FileGamepadFocusRing {
  @Prop active: boolean = false
  @Prop itemPath: string = ''
  @Prop widthVp: number = 120
  @Prop heightVp: number = 120

  build() {
    if (this.active) {
      Row() {}
        .id('file-gamepad-focus:' + this.itemPath)
        .width(this.widthVp).height(this.heightVp)
        .border({ width: 1.5, radius: 9, color: '#E0EEFF' })
        .outline({ width: 1, radius: 9, color: '#B23B76CF' })
        .linearGradient({ direction: GradientDirection.Bottom,
          colors: [['#2376AEFF', 0], ['#0076AEFF', 0.68]] })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
  }
}

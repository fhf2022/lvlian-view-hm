import { uiMaterial } from '@kit.ArkUI'

/** Create once per owning component, never during layout or a drag update. */
export class GlassMaterial {
  static bar(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
      colorInvert: true, applyShadow: true, interactive: true,
      lightEffect: { color: '#66FFFFFF' } })
  }

  static timeline(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
      colorInvert: true, applyShadow: false, interactive: true,
      lightEffect: { color: '#66FFFFFF' } })
  }

  static overlay(): uiMaterial.ImmersiveMaterial {
    // Popup/Dialog owns its native surface and shadow. Rows own press feedback;
    // do not deform a complete action list or stack a second material behind it.
    return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
      colorInvert: true, applyShadow: true, interactive: false, lightEffect: null })
  }

  static importSurface(): uiMaterial.ImmersiveMaterial {
    // The draggable ball supplies its own frozen-point press light. Native
    // deformation/light here would drift away from the moving hit surface.
    return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN,
      colorInvert: true, applyShadow: true, interactive: false, lightEffect: null })
  }
}

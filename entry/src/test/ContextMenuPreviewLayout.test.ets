import { describe, it, expect } from '@ohos/hypium'
import { ContextMenuPreviewLayout, ContextPreviewRect } from '../main/ets/model/ContextMenuPreviewLayout'

export default function contextMenuPreviewLayoutTest() {
  describe('contextMenuPreviewLayout', () => {
    const fallback: ContextPreviewRect = { x: 140, y: 280, width: 94, height: 94 }

    it('lifts a grid square from its own center', 0, () => {
      const rect: ContextPreviewRect = { x: 94, y: 240, width: 94, height: 94 }
      const result = ContextMenuPreviewLayout.fit(true, rect, fallback, 376, 800, 32, 28, 540)
      expect(result.width).assertEqual(94)
      expect(result.height).assertEqual(94)
      expect(result.x).assertEqual(94)
      expect(result.y).assertEqual(240)
      expect(result.scale).assertEqual(1.05)
      expect(result.menuHeight).assertEqual(540)
    })

    it('preserves both portrait and landscape waterfall proportions', 0, () => {
      const portrait: ContextPreviewRect = { x: 10, y: 180, width: 178, height: 1000 }
      const landscape: ContextPreviewRect = { x: 10, y: 180, width: 178, height: 89 }
      const tall = ContextMenuPreviewLayout.fit(true, portrait, fallback, 376, 800, 32, 28, 540)
      const wide = ContextMenuPreviewLayout.fit(true, landscape, fallback, 376, 800, 32, 28, 540)
      expect(Math.abs(tall.width / tall.height - 178 / 1000) < 0.000001).assertEqual(true)
      expect(tall.height * tall.scale <= 320).assertEqual(true)
      expect(tall.height * tall.scale + tall.menuHeight + 24 <= 724.000001).assertEqual(true)
      expect(wide.width).assertEqual(178)
      expect(wide.height).assertEqual(89)
    })

    it('keeps the final scaled preview within all screen edges', 0, () => {
      const corners: ContextPreviewRect[] = [
        { x: -20, y: 0, width: 94, height: 94 },
        { x: 310, y: 735, width: 94, height: 94 },
        { x: 10, y: -600, width: 178, height: 1200 }
      ]
      for (const rect of corners) {
        const result = ContextMenuPreviewLayout.fit(true, rect, fallback, 376, 800, 32, 28, 540)
        expect(result.x - result.width * (result.scale - 1) / 2 >= 11.999999).assertEqual(true)
        expect(result.x + result.width * (result.scale + 1) / 2 <= 364.000001).assertEqual(true)
        expect(result.y - result.height * (result.scale - 1) / 2 >= 39.999999).assertEqual(true)
        expect(result.y + result.height * (result.scale + 1) / 2 <= 764.000001).assertEqual(true)
      }
    })

    it('uses the fallback when cached item geometry is missing or offscreen', 0, () => {
      const stale: ContextPreviewRect = { x: 10, y: -1000, width: 94, height: 94 }
      const invalid: ContextPreviewRect = { x: Number.NaN, y: 20, width: 94, height: 94 }
      for (const rect of [null, stale, invalid]) {
        const result = ContextMenuPreviewLayout.fit(true, rect, fallback, 376, 800, 32, 28, 540)
        expect(result.x).assertEqual(fallback.x)
        expect(result.y).assertEqual(fallback.y)
      }
    })

    it('reserves a scrollable action area on small landscape screens', 0, () => {
      const rect: ContextPreviewRect = { x: 300, y: 20, width: 178, height: 400 }
      const result = ContextMenuPreviewLayout.fit(true, rect, fallback, 800, 300, 20, 20, 540)
      expect(result.menuHeight > 0 && result.menuHeight < 540).assertEqual(true)
      expect(result.menuHeight + result.height * result.scale + 24 <= 244.000001).assertEqual(true)
    })

    it('keeps list previews horizontal with the existing scale', 0, () => {
      const result = ContextMenuPreviewLayout.fit(false, null, fallback, 376, 800, 32, 28, 540)
      expect(result.width).assertEqual(324)
      expect(result.height).assertEqual(58)
      expect(result.scale).assertEqual(1)
      expect(result.x).assertEqual(26)
      expect(result.menuHeight).assertEqual(540)
    })
  })
}

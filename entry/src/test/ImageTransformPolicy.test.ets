import { describe, it, expect } from '@ohos/hypium'
import { ImageTransformPolicy } from '../main/ets/media/ImageTransformPolicy'

export default function imageTransformPolicyTest() {
  describe('imageTransformPolicy', () => {
    it('normalizes persisted quarter turns', 0, () => {
      expect(ImageTransformPolicy.normalizedRotation(-90)).assertEqual(270)
      expect(ImageTransformPolicy.normalizedRotation(450)).assertEqual(90)
      expect(ImageTransformPolicy.normalizedRotation(181)).assertEqual(180)
    })

    it('makes a persisted landscape match native landscape geometry', 0, () => {
      const nativeLandscape = ImageTransformPolicy.rotatedSize(1600, 900, 0)
      const persistedLandscape = ImageTransformPolicy.rotatedSize(900, 1600, 90)
      expect(persistedLandscape.width).assertEqual(nativeLandscape.width)
      expect(persistedLandscape.height).assertEqual(nativeLandscape.height)
    })

    it('composes every EXIF axis state with every user rotation', 0, () => {
      const exifRotations: number[] = [0, 0, 180, 0, 270, 90, 90, 270]
      const userRotations: number[] = [0, 90, 180, 270]
      for (const exifRotation of exifRotations) {
        const exifSize = ImageTransformPolicy.rotatedSize(1200, 800, exifRotation)
        for (const userRotation of userRotations) {
          const finalSize = ImageTransformPolicy.rotatedSize(
            exifSize.width, exifSize.height, userRotation)
          const swaps = ImageTransformPolicy.swapsAxes(exifRotation) !==
            ImageTransformPolicy.swapsAxes(userRotation)
          expect(finalSize.width).assertEqual(swaps ? 800 : 1200)
          expect(finalSize.height).assertEqual(swaps ? 1200 : 800)
        }
      }
    })
  })
}

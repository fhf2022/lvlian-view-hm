import { describe, it, expect } from '@ohos/hypium'
import { ThumbnailPolicy } from '../main/ets/media/ThumbnailPolicy'

export default function thumbnailPolicyTest() {
  describe('thumbnailPolicy', () => {
    it('keeps list decode inside the bounded pixel budget', 0, () => {
      const size = ThumbnailPolicy.targetSize(6000, 4000, 'list')
      expect(size.width).assertEqual(256)
      expect(size.height).assertEqual(171)
      expect(ThumbnailPolicy.estimatedPixelBytes(size.width, size.height))
        .assertEqual(256 * 171 * ThumbnailPolicy.BYTES_PER_RGBA_PIXEL)
      expect(ThumbnailPolicy.needsDownsample(6000, 4000, 'list')).assertTrue()
      expect(ThumbnailPolicy.sampleSize(6000, 4000, 'list')).assertEqual(24)
    })

    it('does not enlarge already small thumbnails', 0, () => {
      const size = ThumbnailPolicy.targetSize(120, 80, 'list')
      expect(size.width).assertEqual(120)
      expect(size.height).assertEqual(80)
      expect(ThumbnailPolicy.needsDownsample(120, 80, 'list')).assertFalse()
    })

    it('uses a larger bounded preview profile for the viewer', 0, () => {
      const size = ThumbnailPolicy.targetSize(4000, 3000, 'viewerPreview')
      expect(size.width).assertEqual(1080)
      expect(size.height).assertEqual(810)
      expect(ThumbnailPolicy.needsDownsample(4000, 3000, 'viewerZoom')).assertTrue()
    })
  })
}

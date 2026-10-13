import { describe, it, expect } from '@ohos/hypium'
import { AlbumUploadItem, AlbumUploadPolicy } from '../main/ets/upload/AlbumUploadModel'

export default function albumUploadPolicyTest() {
  describe('albumUploadPolicy', () => {
    it('keeps retry names stable and separates source versions', 0, () => {
      const item = new AlbumUploadItem()
      item.uri = 'photo://source/1'; item.name = '图片.jpg'; item.size = 1024; item.modified = 1000
      const name = AlbumUploadPolicy.alternateName(item, 0)
      expect(AlbumUploadPolicy.alternateName(item, 0)).assertEqual(name)
      item.modified++
      expect(AlbumUploadPolicy.alternateName(item, 0) !== name).assertEqual(true)
      expect(AlbumUploadPolicy.alternateName(item, 1) !== AlbumUploadPolicy.alternateName(item, 0)).assertEqual(true)
    })
    it('bounds long conflict names while retaining the extension', 0, () => {
      const item = new AlbumUploadItem()
      item.uri = 'photo://source/2'; item.name = '图'.repeat(200) + '.jpeg'; item.size = 2048
      const name = AlbumUploadPolicy.alternateName(item, 0)
      expect(name.endsWith('.jpeg')).assertEqual(true)
      expect(name.length < 100).assertEqual(true)
      item.name = 'a'.repeat(49) + '😀图片.jpeg'
      expect(encodeURIComponent(AlbumUploadPolicy.alternateName(item, 0)).length > 0).assertEqual(true)
    })
    it('rejects names that can escape a destination or alter upload headers', 0, () => {
      for (const name of ['', '.', '..', '../a.jpg', 'a\\b.jpg', 'a\r\nb.jpg', 'a\x00.jpg']) {
        expect(AlbumUploadPolicy.validName(name)).assertEqual(false)
      }
      expect(AlbumUploadPolicy.validName('普通图片 (1).jpg')).assertEqual(true)
    })
  })
}

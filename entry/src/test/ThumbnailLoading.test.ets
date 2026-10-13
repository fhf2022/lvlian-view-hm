import { describe, it, expect } from '@ohos/hypium'
import { FileEntry } from '../main/ets/model/FileEntry'
import { FileEntryDataSource } from '../main/ets/model/FileEntryDataSource'
import { PreviewLoadQueue } from '../main/ets/media/PreviewLoadQueue'

export default function thumbnailLoadingTest() {
  describe('thumbnailLoading', () => {
    it('keeps mounted observed entries attached after a descriptor refresh', 0, () => {
      const mounted = new FileEntry()
      mounted.path = '/photo.jpg'
      mounted.previewRevision = 4
      const source = new FileEntryDataSource([mounted])
      source.bumpInPlace = true
      const fresh = mounted.clone()
      fresh.thumbnailUrl = 'https://nas/new-signature'
      fresh.previewRevision = 0
      source.replace([fresh])
      source.notifyItemChanged(0)
      expect(source.getData(0) === mounted).assertEqual(true)
      expect(mounted.thumbnailUrl).assertEqual(fresh.thumbnailUrl)
      expect(mounted.previewRevision).assertEqual(5)
      fresh.size = 500
      source.replace([fresh])
      expect(source.getData(0) === mounted).assertEqual(true)
      expect(mounted.size).assertEqual(500)
    })

    it('maintains path indexes through append insert reorder and removal', 0, () => {
      const a = new FileEntry()
      a.path = '/a'
      const b = new FileEntry()
      b.path = '/b'
      const c = new FileEntry()
      c.path = '/c'
      const source = new FileEntryDataSource([a])
      source.append([b])
      source.insertAt(1, c)
      expect(source.indexOfPath('/b')).assertEqual(2)
      expect(source.indexOfPath('/c')).assertEqual(1)
      source.replace([b, a])
      expect(source.indexOfPath('/b')).assertEqual(0)
      expect(source.indexOfPath('/c')).assertEqual(-1)
      source.replace([])
      expect(source.indexOfPath('/a')).assertEqual(-1)
    })

    it('promotes visible requests without changing their original owner runner', 0, async () => {
      const queue = new PreviewLoadQueue(1, 8)
      let release: () => void = (): void => {}
      const started: string[] = []
      queue.enqueue('active', 0, (): Promise<void> => new Promise<void>((resolve): void => {
        release = resolve
      }))
      queue.enqueue('adjacent', 5, async (): Promise<void> => { started.push('adjacent') })
      queue.enqueue('visible', 10, async (): Promise<void> => { started.push('visible') })
      expect(queue.promote('visible', 0)).assertEqual(true)
      expect(queue.enqueue('visible', 0, async (): Promise<void> => { started.push('wrong-owner') }))
        .assertEqual(false)
      release()
      await new Promise<void>((resolve): void => { setTimeout(resolve, 0) })
      expect(started.join(',')).assertEqual('visible,adjacent')
      expect(queue.activeCountValue()).assertEqual(0)
    })
  })
}

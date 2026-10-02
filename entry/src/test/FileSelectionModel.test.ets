import { describe, it, expect } from '@ohos/hypium'
import { FileSelectionModel } from '../main/ets/model/FileSelectionModel'

export default function fileSelectionModelTest() {
  describe('fileSelectionModel', () => {
    it('updates the same cell state for rapid toggles and replacement', 0, () => {
      const model = new FileSelectionModel()
      const state = model.stateFor('a')
      const other = model.stateFor('b')
      model.toggle('a')
      expect(state.selected).assertEqual(true)
      model.toggle('a')
      expect(state.selected).assertEqual(false)
      model.replace(['a', 'a', 'b'])
      expect(model.count()).assertEqual(2)
      expect(model.stateFor('a') === state).assertEqual(true)
      model.replace(['b'])
      expect(state.selected).assertEqual(false)
      expect(other.selected).assertEqual(true)
    })

    it('inverts each mixed item inclusively and preserves selections outside', 0, () => {
      const model = new FileSelectionModel()
      model.replace(['b', 'd', 'outside'])
      model.beginRange(1, ['a', 'b', 'c', 'd', 'e'])
      model.extendRange(3)
      expect(model.paths().sort().join(',')).assertEqual('c,outside')
      expect(model.extendRange(3)).assertEqual(false)
      model.extendRange(2)
      expect(model.paths().sort().join(',')).assertEqual('c,d,outside')
      model.extendRange(0)
      expect(model.paths().sort().join(',')).assertEqual('a,d,outside')
    })

    it('a stationary long press and ended gesture cannot change selection', 0, () => {
      const model = new FileSelectionModel()
      model.replace(['a'])
      model.beginRange(0, ['a', 'b'])
      model.endRange()
      expect(model.extendRange(1)).assertEqual(false)
      expect(model.paths().join(',')).assertEqual('a')
      model.beginRange(1, ['a', 'b'])
      model.replace([])
      expect(model.extendRange(0)).assertEqual(false)
    })

    it('freezes displayed ordering and supports a singleton interval', 0, () => {
      const paths = ['a', 'b', 'c']
      const model = new FileSelectionModel()
      model.beginRange(1, paths)
      paths[1] = 'new-directory'
      model.extendRange(1)
      expect(model.paths().join(',')).assertEqual('b')
      expect(model.extendRange(-1)).assertEqual(false)
      expect(model.extendRange(3)).assertEqual(false)
    })

    it('matches snapshot XOR through forward, backward and crossing moves', 0, () => {
      const paths: string[] = []
      for (let index = 0; index < 32; index++) {
        paths.push(index.toString())
      }
      for (let anchor = 0; anchor < paths.length; anchor++) {
        const initial = paths.filter((_path: string, index: number): boolean => index % 3 === 0)
        initial.push('outside')
        const model = new FileSelectionModel()
        model.replace(initial)
        model.beginRange(anchor, paths)
        for (let move = 0; move < 64; move++) {
          const target = (move * 17 + anchor * 7) % paths.length
          const expected = new Set<string>(initial)
          for (let index = Math.min(anchor, target); index <= Math.max(anchor, target); index++) {
            if (expected.has(paths[index])) {
              expected.delete(paths[index])
            } else {
              expected.add(paths[index])
            }
          }
          model.extendRange(target)
          expect(model.paths().sort().join(',')).assertEqual(Array.from(expected).sort().join(','))
          expect(model.count()).assertEqual(expected.size)
        }
      }
    })
  })
}

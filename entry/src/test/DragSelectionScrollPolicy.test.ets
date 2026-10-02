import { describe, it, expect } from '@ohos/hypium'
import { DragSelectionScrollPolicy } from '../main/ets/model/DragSelectionScrollPolicy'

export default function dragSelectionScrollPolicyTest() {
  describe('dragSelectionScrollPolicy', () => {
    it('stays still in the middle and scrolls in the correct edge direction', 0, () => {
      expect(DragSelectionScrollPolicy.velocity(400, 100, 700)).assertEqual(0)
      expect(DragSelectionScrollPolicy.velocity(156, 100, 700)).assertEqual(0)
      expect(DragSelectionScrollPolicy.velocity(644, 100, 700)).assertEqual(0)
      expect(DragSelectionScrollPolicy.velocity(120, 100, 700) < 0).assertEqual(true)
      expect(DragSelectionScrollPolicy.velocity(680, 100, 700) > 0).assertEqual(true)
    })

    it('accelerates near the edge and caps speed outside the viewport', 0, () => {
      expect(DragSelectionScrollPolicy.velocity(690, 100, 700) >
        DragSelectionScrollPolicy.velocity(650, 100, 700)).assertEqual(true)
      expect(DragSelectionScrollPolicy.velocity(10000, 100, 700)).assertEqual(720)
      expect(DragSelectionScrollPolicy.velocity(-10000, 100, 700)).assertEqual(-720)
    })

    it('keeps edge zones apart in a small viewport', 0, () => {
      expect(DragSelectionScrollPolicy.velocity(130, 100, 160)).assertEqual(0)
      expect(DragSelectionScrollPolicy.velocity(110, 100, 160) < 0).assertEqual(true)
      expect(DragSelectionScrollPolicy.velocity(150, 100, 160) > 0).assertEqual(true)
    })

    it('does not move until layout has a valid viewport', 0, () => {
      expect(DragSelectionScrollPolicy.velocity(100, 0, 0)).assertEqual(0)
      expect(DragSelectionScrollPolicy.velocity(100, 300, 200)).assertEqual(0)
      expect(DragSelectionScrollPolicy.velocity(Number.NaN, 0, 500)).assertEqual(0)
    })

    it('caps elapsed time to prevent a jump after a delayed frame', 0, () => {
      expect(DragSelectionScrollPolicy.step(720, 16)).assertEqual(11.52)
      expect(DragSelectionScrollPolicy.step(720, 1000)).assertEqual(23.04)
      expect(DragSelectionScrollPolicy.step(-720, 16)).assertEqual(-11.52)
      expect(DragSelectionScrollPolicy.step(720, -1)).assertEqual(0)
    })
  })
}

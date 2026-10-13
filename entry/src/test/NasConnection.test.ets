import { describe, it, expect } from '@ohos/hypium'
import { NasConnection } from '../main/ets/core/network/NasConnection'
import { OfflineAccountProfile } from '../main/ets/core/session/OfflineAccountProfile'
import { UgreenError, UgreenErrorKind } from '../main/ets/ugreen/UgreenErrors'

export default function nasConnectionTest() {
  describe('nasConnection', () => {
    it('ignores a timeout from before a successful request', 0, () => {
      const connection = new NasConnection()
      connection.setForeground(false)
      connection.configure('https://nas', async (): Promise<boolean> => true)
      const old = connection.begin('https://nas/thumbnail')
      const fresh = connection.begin('https://nas/file')
      connection.response('https://nas/file', fresh, 200)
      connection.failed('https://nas/thumbnail', old)
      expect(connection.current()).assertEqual('online')
      connection.clear()
    })

    it('blocks misses during an outage without affecting cloud requests', 0, () => {
      const connection = new NasConnection()
      connection.setForeground(false)
      connection.configure('https://nas', async (): Promise<boolean> => false)
      connection.failed('https://nas/file', connection.begin('https://nas/file'))
      let blocked = false
      try { connection.begin('https://nas/next') }
      catch (error) { blocked = error instanceof UgreenError && error.kind === UgreenErrorKind.NAS_UNAVAILABLE }
      expect(blocked).assertEqual(true)
      expect(connection.begin('https://cloud/resolve')).assertEqual(0)
      connection.clear()
    })

    it('coalesces repeated reconnect taps into one probe', 0, async () => {
      const connection = new NasConnection()
      let requests = 0
      connection.configure('https://nas', async (): Promise<boolean> => { requests += 1; return true })
      connection.markUnavailable()
      const first = connection.retryNow()
      const second = connection.retryNow()
      await first
      await second
      expect(requests).assertEqual(1)
      expect(connection.current()).assertEqual('online')
      connection.clear()
    })

    it('keeps an individual permission or missing-file response online', 0, () => {
      const connection = new NasConnection()
      connection.setForeground(false)
      connection.configure('https://nas', async (): Promise<boolean> => true)
      connection.response('https://nas/forbidden', connection.begin('https://nas/forbidden'), 403)
      connection.response('https://nas/missing', connection.begin('https://nas/missing'), 404)
      expect(connection.current()).assertEqual('online')
      connection.clear()
    })

    it('restores a cache identity only for the same NAS account', 0, () => {
      const profile = new OfflineAccountProfile()
      profile.linkId = 'nas-link'
      profile.username = 'user'
      profile.baseUrl = 'https://nas'
      profile.uid = 'uid'
      const value = JSON.stringify(profile)
      expect(OfflineAccountProfile.read(value, 'nas-link', 'user') !== null).assertEqual(true)
      expect(OfflineAccountProfile.read(value, 'other-nas', 'user') === null).assertEqual(true)
      expect(OfflineAccountProfile.read(value, 'nas-link', 'other-user') === null).assertEqual(true)
    })
  })
}

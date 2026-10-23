import { asset } from '@kit.AssetStoreKit'
import { util } from '@kit.ArkTS'
import { preferences } from '@kit.ArkData'
import { BusinessError } from '@kit.BasicServicesKit'

interface SavedLogin { linkId: string; username: string; password: string }

/** One remembered login, matching the existing UI. Secrets never enter labels or logs. */
export class LoginCredentialStore {
  private static writing: Promise<void> = Promise.resolve()
  private static alias(): Uint8Array {
    return new util.TextEncoder().encodeInto('linkfiles-remembered-login-v1')
  }

  static async read(store: preferences.Preferences, linkId: string, username: string,
    remember: boolean): Promise<string> {
    await LoginCredentialStore.writing
    if (!remember) {
      await LoginCredentialStore.save(store, linkId, username, '')
      return ''
    }
    const query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, LoginCredentialStore.alias())
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    let savedPassword = ''
    try {
      const results = await asset.query(query)
      const bytes = results.length > 0 ? results[0].get(asset.Tag.SECRET) as Uint8Array : undefined
      if (bytes !== undefined) {
        const saved = JSON.parse(new util.TextDecoder().decodeToString(bytes)) as SavedLogin
        if (saved.linkId === linkId && saved.username === username) { savedPassword = saved.password }
      }
    } catch (error) {
      if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw error as Error }
    }
    const legacy = await store.get('cloud_password', '')
    if (savedPassword.length === 0 && typeof legacy === 'string' && legacy.length > 0) {
      await LoginCredentialStore.save(store, linkId, username, legacy)
      return legacy
    }
    if (typeof legacy === 'string' && legacy.length > 0) {
      await store.delete('cloud_password')
      await store.flush()
    }
    return savedPassword
  }

  static async save(store: preferences.Preferences, linkId: string, username: string,
    password: string): Promise<void> {
    const operation = LoginCredentialStore.writing.then((): Promise<void> =>
      LoginCredentialStore.write(store, linkId, username, password))
    LoginCredentialStore.writing = operation.catch((): void => {})
    await operation
  }

  private static async write(store: preferences.Preferences, linkId: string, username: string,
    password: string): Promise<void> {
    const attributes: asset.AssetMap = new Map()
    attributes.set(asset.Tag.ALIAS, LoginCredentialStore.alias())
    if (password.length > 0) {
      const saved: SavedLogin = { linkId: linkId, username: username, password: password }
      attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(JSON.stringify(saved)))
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER)
      attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE)
      await asset.add(attributes)
    } else {
      try { await asset.remove(attributes) } catch (error) {
        if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw error as Error }
      }
    }
    // Delete the old copy only after the system store has committed.
    await store.delete('cloud_password')
    await store.flush()
  }
}

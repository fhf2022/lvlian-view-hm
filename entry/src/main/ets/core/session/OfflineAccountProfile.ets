/** Cache identity only; never a token or substitute for server authentication. */
export class OfflineAccountProfile {
  linkId: string = ''
  username: string = ''
  baseUrl: string = ''
  uid: string = ''
  path: string = ''
  rootType: number = 3
  personalRootType: number = 4
  rootKind: 'personal' | 'shared' = 'personal'

  static read(value: string, linkId: string, username: string): OfflineAccountProfile | null {
    try {
      const profile = JSON.parse(value) as OfflineAccountProfile
      if (profile.linkId !== linkId || profile.username !== username ||
        typeof profile.uid !== 'string' || profile.uid.length === 0 || profile.uid.includes('|') ||
        typeof profile.baseUrl !== 'string' || !/^https?:\/\/[^\s|]+$/.test(profile.baseUrl) ||
        typeof profile.path !== 'string' || (profile.path.length > 0 && !profile.path.startsWith('/')) ||
        [2, 3, 4].indexOf(profile.rootType) < 0 || [2, 4].indexOf(profile.personalRootType) < 0 ||
        (profile.rootKind !== 'personal' && profile.rootKind !== 'shared')) {
        return null
      }
      return profile
    } catch (_) { return null }
  }
}

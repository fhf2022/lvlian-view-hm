import { common } from '@kit.AbilityKit'
import { privacyManager } from '@kit.AppGalleryKit'
import { preferences } from '@kit.ArkData'
import { LocalAlbumSource } from '../../upload/LocalAlbumSource'
import { TransferBackgroundManager } from '../../transfer/TransferBackgroundManager'

/** Platform consent is authoritative; a local flag records only the optional gallery prompt. */
export class StartupAuthorization {
  private static instance: StartupAuthorization = new StartupAuthorization()
  static shared(): StartupAuthorization { return StartupAuthorization.instance }
  private initial: Promise<boolean> = Promise.resolve(false)
  private resolveInitial: ((allowed: boolean) => void) | null = null
  private pending: Promise<boolean> | null = null
  private status: string = ''

  prepare(): void {
    this.initial = new Promise<boolean>((resolve) => { this.resolveInitial = resolve })
    this.status = ''
  }

  waitForInitial(): Promise<boolean> { return this.initial }
  message(): string { return this.status }

  async beginInitial(context: common.UIAbilityContext): Promise<void> {
    const allowed = await this.authorize(context)
    this.resolveInitial?.(allowed)
    this.resolveInitial = null
  }

  authorize(context: common.UIAbilityContext): Promise<boolean> {
    if (this.pending !== null) { return this.pending }
    this.pending = this.run(context).finally(() => { this.pending = null })
    return this.pending
  }

  private privacyAgreed(results: privacyManager.AppPrivacyResult[], version: number): boolean {
    const agreement = results.find((item: privacyManager.AppPrivacyResult): boolean =>
      item.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT)
    return agreement !== undefined && agreement.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED &&
      agreement.versionCode === version
  }

  private async run(context: common.UIAbilityContext): Promise<boolean> {
    this.status = ''
    try {
      const info = privacyManager.getAppPrivacyMgmtInfo()
      const statement = info.privacyInfo.find((item: privacyManager.AppPrivacyLink): boolean =>
        item.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK)
      if (info.type !== privacyManager.AppPrivacyMgmtType.FULL_MODE || statement === undefined) {
        this.status = '隐私声明暂不可用，请重试'
        return false
      }
      if (!this.privacyAgreed(privacyManager.getAppPrivacyResult(), statement.versionCode)) {
        const consent = await privacyManager.requestAppPrivacyConsent(context)
        if (!this.privacyAgreed(consent.results, statement.versionCode)) {
          this.status = '同意隐私声明后才能使用'
          return false
        }
      }
    } catch (error) {
      console.warn('[StartupAuthorization] privacy request failed: ' + JSON.stringify(error))
      this.status = '暂时无法打开隐私声明，请重试'
      return false
    }

    // This optional permission follows consent once, and never gates NAS browsing.
    // A denied permission can be requested again by an explicit album action.
    try {
      const store = await preferences.getPreferences(context, 'linkfiles-startup-authorization')
      if (await store.get('gallery_prompted', false) !== true) {
        try { await new LocalAlbumSource(context).requestPermission() }
        catch (_) { console.info('[StartupAuthorization] gallery access not granted') }
        await store.put('gallery_prompted', true)
        await store.flush()
      }
    } catch (error) {
      console.warn('[StartupAuthorization] gallery prompt state unavailable: ' + JSON.stringify(error))
    }
    const background = TransferBackgroundManager.shared()
    background.initialize(context)
    try { await background.requestNotificationPermission() } catch (_) {}
    return true
  }
}

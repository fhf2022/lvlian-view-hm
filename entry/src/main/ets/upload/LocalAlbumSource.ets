import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { dataSharePredicates } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { AlbumUploadItem, AlbumUploadSource, LocalImageAlbum } from './AlbumUploadModel'

/** Keeps permission recovery separate from album or NAS failures. */
export class LocalAlbumPermissionError extends Error {
  constructor(message: string = '需要允许读取图片') { super(message); this.name = 'LocalAlbumPermissionError' }
}

/** Native result sets are bounded to 200 objects per IPC, and always released. */
export class LocalAlbumSource implements AlbumUploadSource {
  private context: common.UIAbilityContext
  constructor(context: common.UIAbilityContext) { this.context = context }

  async requestPermission(allowSettings: boolean = false): Promise<void> {
    const manager = abilityAccessCtrl.createAtManager()
    const result = await manager.requestPermissionsFromUser(this.context, ['ohos.permission.READ_IMAGEVIDEO'])
    if (result.errorReasons?.[0] === 4) {
      throw new LocalAlbumPermissionError('请重新打开应用完成隐私授权')
    }
    if (result.authResults.length === 1 && result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return
    }
    if (result.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
      throw new Error('图库授权请求无效，请检查应用权限配置')
    }
    // A fresh refusal ends this attempt. Only a previous refusal that prevents
    // the ordinary dialog uses the official settings dialog on an explicit album action.
    if (allowSettings && result.dialogShownResults?.[0] === false) {
      const granted = await manager.requestPermissionOnSetting(this.context, ['ohos.permission.READ_IMAGEVIDEO'])
      if (granted.length === 1 && granted[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) { return }
    }
    throw new LocalAlbumPermissionError()
  }

  private async helper(): Promise<photoAccessHelper.PhotoAccessHelper> {
    const helper = photoAccessHelper.getPhotoAccessHelper(this.context)
    try {
      await helper.setAssetCompatibleCapability({ supportedHighResolution: true })
      return helper
    } catch (error) { helper.release(); throw error as Error }
  }

  private images(): dataSharePredicates.DataSharePredicates {
    return new dataSharePredicates.DataSharePredicates()
      .equalTo(photoAccessHelper.PhotoKeys.PHOTO_TYPE, photoAccessHelper.PhotoType.IMAGE)
  }

  async selectedAlbum(uri: string, name: string): Promise<LocalImageAlbum> {
    const helper = await this.helper()
    try {
      // The official picker can also return system collections (for example favourites).
      const types: photoAccessHelper.AlbumType[] = [photoAccessHelper.AlbumType.USER,
        photoAccessHelper.AlbumType.SOURCE, photoAccessHelper.AlbumType.SYSTEM]
      for (const type of types) {
        const albums = await helper.getAlbums(type, photoAccessHelper.AlbumSubtype.ANY)
        try {
          for (let index = 0; index < albums.getCount(); index++) {
            const album = await albums.getObjectByPosition(index)
            if (album.albumUri !== uri) { continue }
            const entry = new LocalImageAlbum()
            entry.uri = album.albumUri; entry.name = album.albumName || name; entry.path = album.lpath || ''
            entry.type = album.albumType; entry.subtype = album.albumSubtype
            const photos = await album.getAssets({ predicates: this.images(), fetchColumns: [] })
            try { entry.localCount = photos.getCount() } finally { photos.close() }
            const moving = await album.getAssets({ predicates: this.images().equalTo(
              photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE, photoAccessHelper.PhotoSubtype.MOVING_PHOTO), fetchColumns: [] })
            try { entry.movingCount = moving.getCount() } finally { moving.close() }
            return entry
          }
        } finally { albums.close() }
      }
      throw new Error('所选相册暂不可读取，请到系统图库缓存后重新选择')
    } finally { helper.release() }
  }

  private async resolve(helper: photoAccessHelper.PhotoAccessHelper,
    reference: LocalImageAlbum): Promise<photoAccessHelper.Album> {
    const albums = await helper.getAlbums(reference.type, photoAccessHelper.AlbumSubtype.ANY)
    try {
      for (let index = 0; index < albums.getCount(); index++) {
        const album = await albums.getObjectByPosition(index)
        if (album.albumUri === reference.uri) { return album }
      }
      throw new Error('本地图片文件夹已不存在，请刷新后重新选择')
    } finally { albums.close() }
  }

  async snapshot(reference: LocalImageAlbum, consume: (items: AlbumUploadItem[]) => Promise<void>,
    check: () => void): Promise<number> {
    const helper = await this.helper()
    let result: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> | null = null
    try {
      const album = await this.resolve(helper, reference)
      const changeTime = album.changeTime || 0
      result = await album.getAssets({ predicates: this.images(), fetchColumns:
        [photoAccessHelper.PhotoKeys.SIZE, photoAccessHelper.PhotoKeys.DATE_MODIFIED_MS,
          photoAccessHelper.PhotoKeys.DISPLAY_NAME] })
      const expected = result.getCount()
      if (expected === 0) { throw new Error('此文件夹暂无可读取的本地图片，请先到系统图库缓存后刷新') }
      const seen: Set<string> = new Set<string>()
      for (let offset = 0; offset < expected; offset += 200) {
        check()
        const indices: number[] = []
        for (let index = offset; index < Math.min(expected, offset + 200); index++) { indices.push(index) }
        const assets = await result.getObjectsByIndexSet(indices)
        const items: AlbumUploadItem[] = []
        for (const asset of assets) {
          if (seen.has(asset.uri)) { throw new Error('整理期间图片文件夹发生变化，请刷新后重试') }
          seen.add(asset.uri)
          const item = new AlbumUploadItem()
          item.id = util.generateRandomUUID(false); item.uri = asset.uri; item.name = asset.displayName
          item.size = asset.get(photoAccessHelper.PhotoKeys.SIZE) as number
          item.modified = asset.get(photoAccessHelper.PhotoKeys.DATE_MODIFIED_MS) as number
          items.push(item)
        }
        await consume(items)
      }
      check()
      const current = await this.resolve(helper, reference)
      const recount = await current.getAssets({ predicates: this.images(), fetchColumns: [] })
      try {
        if (seen.size !== expected || recount.getCount() !== expected ||
          (changeTime > 0 && current.changeTime !== changeTime)) {
          throw new Error('整理期间图片文件夹发生变化，请刷新后重试')
        }
      } finally { recount.close() }
      return expected
    } finally { if (result) { result.close() }; helper.release() }
  }

  async validate(item: AlbumUploadItem): Promise<void> {
    const helper = await this.helper()
    try {
      const result = await helper.getAssets({ predicates: new dataSharePredicates.DataSharePredicates()
        .equalTo(photoAccessHelper.PhotoKeys.URI, item.uri), fetchColumns:
        [photoAccessHelper.PhotoKeys.SIZE, photoAccessHelper.PhotoKeys.DATE_MODIFIED_MS] })
      try {
        if (result.getCount() !== 1) { throw new Error('图片已删除或读取授权已失效') }
        const asset = await result.getFirstObject()
        if (asset.get(photoAccessHelper.PhotoKeys.SIZE) !== item.size ||
          asset.get(photoAccessHelper.PhotoKeys.DATE_MODIFIED_MS) !== item.modified) {
          throw new Error('图片已修改，请在新批次中上传最新版本')
        }
      } finally { result.close() }
    } finally { helper.release() }
  }
}

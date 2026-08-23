import { Context } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'
import { FileEntry } from '../model/FileEntry'

export class ImageRotationRecord {
  path: string = ''
  size: number = 0
  modifiedTime: number = 0
  angle: number = 0
  previewOrientation: number = 0
}

class StoredImageRotationState {
  angle: number = 0
  previewOrientation: number = 0
}

/**
 * Durable, app-local metadata for image display orientation.
 *
 * The user's normalized quarter-turn and the NAS-thumbnail base correction
 * are stored independently from image bytes. Clearing or evicting original
 * and thumbnail files therefore cannot change the direction of an image.
 */
export class ImageRotationStore {
  private static readonly DATABASE_NAME: string = 'ugreen_image_rotation'
  private static readonly DATABASE_VERSION: number = 2

  private store: relationalStore.RdbStore | null = null
  private initPromise: Promise<void> | null = null
  private writeQueue: Promise<void> = Promise.resolve()

  async initialize(context: Context): Promise<void> {
    if (this.initPromise === null) {
      this.initPromise = this.open(context)
    }
    await this.initPromise
  }

  async readDirectory(scope: string, parentPath: string): Promise<ImageRotationRecord[]> {
    const store = await this.readyStore()
    if (store === null || scope.length === 0 || parentPath.length === 0) {
      return []
    }

    const records: ImageRotationRecord[] = []
    let resultSet: relationalStore.ResultSet | null = null
    try {
      resultSet = await store.querySql(
        'SELECT remote_path, file_size, modified_time, angle, preview_orientation ' +
          'FROM image_rotation WHERE scope = ? AND parent_path = ?',
        [scope, parentPath]
      )
      if (resultSet.goToFirstRow()) {
        do {
          const angle = this.normalizedAngle(resultSet.getLong(3))
          const previewOrientation = this.normalizedOrientation(resultSet.getLong(4))
          if (angle === 0 && previewOrientation === 0) {
            continue
          }
          const record = new ImageRotationRecord()
          record.path = resultSet.getString(0)
          record.size = resultSet.getLong(1)
          record.modifiedTime = resultSet.getLong(2)
          record.angle = angle
          record.previewOrientation = previewOrientation
          records.push(record)
        } while (resultSet.goToNextRow())
      }
    } catch (error) {
      console.warn('[UgreenImage] read rotation metadata failed: ' + JSON.stringify(error))
    } finally {
      if (resultSet !== null) {
        resultSet.close()
      }
    }
    return records
  }

  async save(scope: string, entry: FileEntry, angle: number): Promise<void> {
    const normalized = this.normalizedAngle(angle)
    if (scope.length === 0 || entry.path.length === 0) {
      return
    }
    const operation = this.writeQueue.then(async (): Promise<void> => {
      const store = await this.readyStore()
      if (store === null) {
        return
      }
      const state = await this.readState(store, scope, entry.path)
      if (normalized === 0 && state.previewOrientation === 0) {
        await store.executeSql(
          'DELETE FROM image_rotation WHERE scope = ? AND remote_path = ?',
          [scope, entry.path]
        )
        return
      }
      await this.writeRecord(store, scope, entry, normalized, state.previewOrientation)
    })
    this.writeQueue = operation.catch((): void => {})
    await operation
  }

  async savePreviewOrientation(scope: string, entry: FileEntry, orientation: number): Promise<void> {
    const normalized = this.normalizedOrientation(orientation)
    if (scope.length === 0 || entry.path.length === 0) {
      return
    }
    const operation = this.writeQueue.then(async (): Promise<void> => {
      const store = await this.readyStore()
      if (store === null) {
        return
      }
      const state = await this.readState(store, scope, entry.path)
      if (normalized === 0 && state.angle === 0) {
        await store.executeSql(
          'DELETE FROM image_rotation WHERE scope = ? AND remote_path = ?',
          [scope, entry.path]
        )
        return
      }
      await this.writeRecord(store, scope, entry, state.angle, normalized)
    })
    this.writeQueue = operation.catch((): void => {})
    await operation
  }

  async remove(scope: string, path: string): Promise<void> {
    if (scope.length === 0 || path.length === 0) {
      return
    }
    const operation = this.writeQueue.then(async (): Promise<void> => {
      const store = await this.readyStore()
      if (store !== null) {
        await store.executeSql(
          'DELETE FROM image_rotation WHERE scope = ? AND remote_path = ?',
          [scope, path]
        )
      }
    })
    this.writeQueue = operation.catch((): void => {})
    await operation
  }

  private async open(context: Context): Promise<void> {
    try {
      const config: relationalStore.StoreConfig = {
        name: ImageRotationStore.DATABASE_NAME,
        securityLevel: relationalStore.SecurityLevel.S2,
        encrypt: true,
        allowRebuild: true
      }
      this.store = await relationalStore.getRdbStore(context, config)
      await this.store.executeSql(
        'CREATE TABLE IF NOT EXISTS image_rotation (' +
          'scope TEXT NOT NULL, ' +
          'remote_path TEXT NOT NULL, ' +
          'parent_path TEXT NOT NULL, ' +
          'file_size INTEGER NOT NULL, ' +
          'modified_time INTEGER NOT NULL, ' +
          'angle INTEGER NOT NULL, ' +
          'preview_orientation INTEGER NOT NULL DEFAULT 0, ' +
          'updated_at INTEGER NOT NULL, ' +
          'PRIMARY KEY (scope, remote_path)' +
        ')'
      )
      await this.store.executeSql(
        'CREATE INDEX IF NOT EXISTS idx_image_rotation_directory ' +
          'ON image_rotation (scope, parent_path)'
      )
      if (this.store.version < 2) {
        try {
          await this.store.executeSql(
            'ALTER TABLE image_rotation ADD COLUMN preview_orientation INTEGER NOT NULL DEFAULT 0'
          )
        } catch (_) {
          // A freshly created v2 table already contains this column.
        }
      }
      this.store.version = ImageRotationStore.DATABASE_VERSION
    } catch (error) {
      console.warn('[UgreenImage] rotation metadata database unavailable: ' + JSON.stringify(error))
      this.store = null
    }
  }

  private async readyStore(): Promise<relationalStore.RdbStore | null> {
    if (this.initPromise === null) {
      return null
    }
    await this.initPromise
    return this.store
  }

  private parentPath(path: string): string {
    const normalized = path.replace(/\/+$/, '')
    const separator = normalized.lastIndexOf('/')
    if (separator <= 0) {
      return '/'
    }
    return normalized.substring(0, separator)
  }

  private async readState(store: relationalStore.RdbStore, scope: string,
    path: string): Promise<StoredImageRotationState> {
    const state = new StoredImageRotationState()
    let resultSet: relationalStore.ResultSet | null = null
    try {
      resultSet = await store.querySql(
        'SELECT angle, preview_orientation FROM image_rotation WHERE scope = ? AND remote_path = ?',
        [scope, path]
      )
      if (resultSet.goToFirstRow()) {
        state.angle = this.normalizedAngle(resultSet.getLong(0))
        state.previewOrientation = this.normalizedOrientation(resultSet.getLong(1))
      }
    } finally {
      if (resultSet !== null) {
        resultSet.close()
      }
    }
    return state
  }

  private async writeRecord(store: relationalStore.RdbStore, scope: string,
    entry: FileEntry, angle: number, previewOrientation: number): Promise<void> {
    await store.executeSql(
      'INSERT OR REPLACE INTO image_rotation ' +
        '(scope, remote_path, parent_path, file_size, modified_time, angle, preview_orientation, updated_at) ' +
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [scope, entry.path, this.parentPath(entry.path), entry.size, entry.modifiedTime,
        this.normalizedAngle(angle), this.normalizedOrientation(previewOrientation), Date.now()]
    )
  }

  private normalizedAngle(angle: number): number {
    const rounded = Math.round(angle / 90) * 90
    return ((rounded % 360) + 360) % 360
  }

  private normalizedOrientation(orientation: number): number {
    const rounded = Math.round(orientation)
    return rounded >= 0 && rounded <= 8 ? rounded : 0
  }
}

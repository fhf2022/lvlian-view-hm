import { Context } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'
import { AlbumItemState, AlbumUploadItem, AlbumUploadJob, AlbumUploadState } from './AlbumUploadModel'

/** The manifest stays in SQLite, rather than in the UI or a repeatedly rewritten preference. */
export class AlbumUploadStore {
  private db: relationalStore.RdbStore | null = null
  async initialize(context: Context): Promise<void> {
    if (this.db) { return }
    const db = await relationalStore.getRdbStore(context,
      { name: 'album-upload.db', securityLevel: relationalStore.SecurityLevel.S2, encrypt: true })
    await db.executeSql(`CREATE TABLE IF NOT EXISTS album_jobs (
      id TEXT PRIMARY KEY, scope TEXT NOT NULL, album_uri TEXT, album_name TEXT, destination TEXT,
      root_type INTEGER, state TEXT, total INTEGER, uploaded INTEGER, skipped INTEGER, failed INTEGER,
      bytes INTEGER, created INTEGER, keep_on INTEGER, error TEXT)`)
    await db.executeSql(`CREATE TABLE IF NOT EXISTS album_items (
      id TEXT PRIMARY KEY, batch TEXT NOT NULL, uri TEXT, name TEXT, target TEXT, size INTEGER,
      modified INTEGER, state TEXT, error TEXT, prepared INTEGER, UNIQUE(batch, uri))`)
    await db.executeSql('CREATE INDEX IF NOT EXISTS album_pending ON album_items(batch, state)')
    await db.executeSql("CREATE INDEX IF NOT EXISTS album_unfinished ON album_items(batch) WHERE state IN ('pending','active')")
    await db.executeSql(`CREATE TABLE IF NOT EXISTS album_remote (
      batch TEXT, name TEXT, size INTEGER, directory INTEGER, PRIMARY KEY(batch, name))`)
    await db.executeSql(`CREATE TABLE IF NOT EXISTS album_ledger (
      scope TEXT, destination TEXT, uri TEXT, size INTEGER, modified INTEGER, target TEXT,
      PRIMARY KEY(scope, destination, uri, size, modified))`)
    await db.executeSql("UPDATE album_jobs SET state='paused', error='整理中断，请重新创建任务' WHERE state='building'")
    await db.executeSql("UPDATE album_jobs SET state='paused' WHERE state IN ('running','checking','queued','waiting_foreground')")
    await db.executeSql("UPDATE album_items SET state='pending' WHERE state='active'")
    this.db = db
  }
  private store(): relationalStore.RdbStore {
    if (!this.db) { throw new Error('上传任务存储尚未就绪') }; return this.db
  }
  async save(job: AlbumUploadJob): Promise<void> {
    await this.store().executeSql('INSERT OR REPLACE INTO album_jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [job.id, job.scope, job.albumUri, job.albumName, job.destination, job.rootType, job.state, job.total,
        job.uploaded, job.skipped, job.failed, job.bytes, job.createdAt, job.keepScreenOn ? 1 : 0, job.error])
  }
  async jobs(): Promise<AlbumUploadJob[]> {
    const result = await this.store().querySql('SELECT * FROM album_jobs ORDER BY created DESC')
    const jobs: AlbumUploadJob[] = []
    try {
      while (result.goToNextRow()) {
        const job = new AlbumUploadJob()
        job.id = this.text(result, 'id'); job.scope = this.text(result, 'scope')
        job.albumUri = this.text(result, 'album_uri'); job.albumName = this.text(result, 'album_name')
        job.destination = this.text(result, 'destination'); job.rootType = this.number(result, 'root_type')
        job.state = this.text(result, 'state') as AlbumUploadState
        job.total = this.number(result, 'total'); job.uploaded = this.number(result, 'uploaded')
        job.skipped = this.number(result, 'skipped'); job.failed = this.number(result, 'failed')
        job.bytes = this.number(result, 'bytes'); job.createdAt = this.number(result, 'created')
        job.keepScreenOn = this.number(result, 'keep_on') === 1; job.error = this.text(result, 'error')
        jobs.push(job)
      }
    } finally { result.close() }
    return jobs
  }
  async append(batch: string, items: AlbumUploadItem[]): Promise<void> {
    for (let offset = 0; offset < items.length; offset += 50) {
      const values: relationalStore.ValueType[] = []
      const rows: string[] = []
      for (const item of items.slice(offset, offset + 50)) {
        item.batchId = batch
        rows.push('(?,?,?,?,?,?,?,?,?,?)')
        values.push(item.id, batch, item.uri, item.name, item.targetName, item.size, item.modified, item.state,
          item.error, item.prepared ? 1 : 0)
      }
      await this.store().executeSql('INSERT INTO album_items VALUES ' + rows.join(','), values)
    }
  }
  async update(item: AlbumUploadItem): Promise<void> {
    await this.store().executeSql('UPDATE album_items SET target=?,state=?,error=?,prepared=? WHERE id=?',
      [item.targetName, item.state, item.error, item.prepared ? 1 : 0, item.id])
  }
  async items(batch: string, offset: number = 0, failures: boolean = false): Promise<AlbumUploadItem[]> {
    const result = await this.store().querySql('SELECT * FROM album_items WHERE batch=?' +
      (failures ? " AND state='failed'" : '') + ' ORDER BY rowid LIMIT 100 OFFSET ?', [batch, offset])
    const items: AlbumUploadItem[] = []
    try { while (result.goToNextRow()) { items.push(this.item(result)) } } finally { result.close() }
    return items
  }
  async next(batch: string): Promise<AlbumUploadItem | null> {
    const result = await this.store().querySql("SELECT * FROM album_items INDEXED BY album_unfinished WHERE batch=? AND state IN ('pending','active') ORDER BY rowid LIMIT 1", [batch])
    try { return result.goToNextRow() ? this.item(result) : null } finally { result.close() }
  }
  /** Item state and counters commit together. Recount is reserved for recovery and batch boundaries. */
  async finishItem(job: AlbumUploadJob, item: AlbumUploadItem): Promise<void> {
    const db = this.store()
    const uploaded = job.uploaded, skipped = job.skipped, failed = job.failed, completed = job.completedBytes
    db.beginTransaction()
    try {
      const result = await db.querySql('SELECT state,size FROM album_items WHERE id=? AND batch=?', [item.id, job.id])
      let previous: AlbumItemState
      let size: number
      try {
        if (!result.goToNextRow()) { throw new Error('上传清单条目不存在') }
        previous = this.text(result, 'state') as AlbumItemState
        size = this.number(result, 'size')
      } finally { result.close() }
      await this.update(item)
      job.uploaded += (item.state === 'uploaded' ? 1 : 0) - (previous === 'uploaded' ? 1 : 0)
      job.skipped += (item.state === 'skipped' ? 1 : 0) - (previous === 'skipped' ? 1 : 0)
      job.failed += (item.state === 'failed' ? 1 : 0) - (previous === 'failed' ? 1 : 0)
      job.completedBytes += (item.state === 'uploaded' || item.state === 'skipped' ? item.size : 0) -
        (previous === 'uploaded' || previous === 'skipped' ? size : 0)
      await this.save(job)
      db.commit()
    } catch (error) {
      job.uploaded = uploaded; job.skipped = skipped; job.failed = failed; job.completedBytes = completed
      db.rollBack()
      throw error as Error
    }
  }
  async recount(job: AlbumUploadJob): Promise<void> {
    const result = await this.store().querySql('SELECT state,COUNT(*) AS count,SUM(size) AS size FROM album_items WHERE batch=? GROUP BY state', [job.id])
    job.uploaded = 0; job.skipped = 0; job.failed = 0
    job.completedBytes = 0
    try {
      while (result.goToNextRow()) {
        const state = this.text(result, 'state'); const count = this.number(result, 'count')
        if (state === 'uploaded') { job.uploaded = count }
        if (state === 'skipped') { job.skipped = count }
        if (state === 'failed') { job.failed = count }
        if (state === 'uploaded' || state === 'skipped') { job.completedBytes += this.number(result, 'size') }
      }
    } finally { result.close() }
    await this.save(job)
  }
  async retry(batch: string): Promise<void> {
    await this.store().executeSql("UPDATE album_items SET state='pending',error='' WHERE batch=? AND state='failed'", [batch])
  }
  async clearRemote(batch: string): Promise<void> {
    await this.store().executeSql('DELETE FROM album_remote WHERE batch=?', [batch])
  }
  async remote(batch: string, name: string): Promise<number | null> {
    const result = await this.store().querySql('SELECT size,directory FROM album_remote WHERE batch=? AND name=?', [batch, name])
    try { return result.goToNextRow() ? (this.number(result, 'directory') === 1 ? -1 : this.number(result, 'size')) : null }
    finally { result.close() }
  }
  async rememberRemote(batch: string, name: string, size: number, directory: boolean): Promise<void> {
    await this.store().executeSql('INSERT OR REPLACE INTO album_remote VALUES (?,?,?,?)', [batch, name, size, directory ? 1 : 0])
  }
  async remotePage(batch: string, names: string[], sizes: number[], directories: boolean[]): Promise<void> {
    for (let offset = 0; offset < names.length; offset += 200) {
      const values: relationalStore.ValueType[] = []
      const rows: string[] = []
      for (let index = offset; index < Math.min(names.length, offset + 200); index++) {
        rows.push('(?,?,?,?)'); values.push(batch, names[index], sizes[index], directories[index] ? 1 : 0)
      }
      await this.store().executeSql('INSERT OR REPLACE INTO album_remote VALUES ' + rows.join(','), values)
    }
  }
  async prune(): Promise<void> {
    const obsolete = "SELECT id FROM album_jobs WHERE state='completed' AND id NOT IN (SELECT id FROM album_jobs WHERE state='completed' ORDER BY created DESC LIMIT 20)"
    await this.store().executeSql('DELETE FROM album_items WHERE batch IN (' + obsolete + ')')
    await this.store().executeSql('DELETE FROM album_remote WHERE batch IN (' + obsolete + ')')
    await this.store().executeSql('DELETE FROM album_jobs WHERE id IN (' + obsolete + ')')
  }
  async priorName(job: AlbumUploadJob, item: AlbumUploadItem): Promise<string> {
    const result = await this.store().querySql('SELECT target FROM album_ledger WHERE scope=? AND destination=? AND uri=? AND size=? AND modified=?',
      [job.scope, job.destination, item.uri, item.size, item.modified])
    try { return result.goToNextRow() ? this.text(result, 'target') : '' } finally { result.close() }
  }
  async remember(job: AlbumUploadJob, item: AlbumUploadItem): Promise<void> {
    await this.store().executeSql('INSERT OR REPLACE INTO album_ledger VALUES (?,?,?,?,?,?)',
      [job.scope, job.destination, item.uri, item.size, item.modified, item.targetName])
  }
  async remove(batch: string): Promise<void> {
    await this.store().executeSql('DELETE FROM album_items WHERE batch=?', [batch])
    await this.clearRemote(batch)
    await this.store().executeSql('DELETE FROM album_jobs WHERE id=?', [batch])
  }
  private item(result: relationalStore.ResultSet): AlbumUploadItem {
    const item = new AlbumUploadItem()
    item.id = this.text(result, 'id'); item.batchId = this.text(result, 'batch'); item.uri = this.text(result, 'uri')
    item.name = this.text(result, 'name'); item.targetName = this.text(result, 'target')
    item.size = this.number(result, 'size'); item.modified = this.number(result, 'modified')
    item.state = this.text(result, 'state') as AlbumItemState; item.error = this.text(result, 'error')
    item.prepared = this.number(result, 'prepared') === 1
    return item
  }
  private text(result: relationalStore.ResultSet, column: string): string { return result.getString(result.getColumnIndex(column)) }
  private number(result: relationalStore.ResultSet, column: string): number { return result.getLong(result.getColumnIndex(column)) }
}

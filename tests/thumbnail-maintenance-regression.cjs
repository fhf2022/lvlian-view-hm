// Cancellation must stop a storage-page inventory without treating the
// unvisited half as missing files or publishing an incomplete shared index.
const assert = require('node:assert/strict'), fs = require('node:fs');
const vm = require('node:vm'), ts = require(process.argv[2]);
const exportsObject = {};
let active, queued;
const io = {
  async listFile() { active.lists++; return active.names; },
  async stat(path) {
    active.stats.push(path);
    if (active.holdStats) await active.holdStats;
    return { size: 10, mtime: 1, isFile: () => true };
  },
  async unlink(path) { active.removed.push(path); if (active.onUnlink) active.onUnlink(); }
};
const cache = {
  async runSerialized(fn) { if (queued) await queued; await fn(); },
  reportRemoved(path) { active.invalidated.push(path); },
  invalidateThumbnailInventory() { active.inventoryInvalidated++; },
  primeThumbnailInventory(_directory, files) { active.primed.push(files); }
};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/media/ThumbnailCacheStore.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, console, setTimeout: () => 1, clearTimeout() {},
  require: name => name === '@kit.CoreFileKit' ? { fileIo: io } : { CacheManager: cache } });
const deferred = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
const tick = async () => { for (let i = 0; i < 50; i++) await Promise.resolve(); };
function fixture() {
  active = { lists: 0, stats: [], removed: [], invalidated: [], primed: [], flushed: 0, inventoryInvalidated: 0,
    names: Array.from({ length: 24 }, (_, i) => i + '.thumbnail') };
  queued = null;
  const record = active, store = new exportsObject.ThumbnailCacheStore();
  store.directory = '/files/ugreen-thumbnail-cache';
  store.items = new Map(); store.keysByPath = new Map();
  for (const name of active.names) {
    const path = store.directory + '/' + name;
    store.items.set(name, { path, lastAccessAt: 1, size: 10 }); store.keysByPath.set(path, new Set([name]));
  }
  store.flushPersist = async () => { record.flushed++; };
  return { store, record };
}
(async () => {
  const a = fixture(); await a.store.enforceLimit(1000, () => false);
  assert.equal(a.record.lists, 0); assert.equal(a.record.flushed, 0);

  const b = fixture(), lane = deferred(); queued = lane.promise; let valid = true;
  const waiting = b.store.enforceLimit(1000, () => valid); valid = false; lane.resolve(); await waiting;
  assert.equal(b.record.lists, 0, 'a storage request cancelled in the writer lane never starts');

  const c = fixture(), batch = deferred(); c.record.holdStats = batch.promise; valid = true;
  const scan = c.store.enforceLimit(1000, () => valid); await tick();
  assert.equal(c.record.stats.length, 8, 'only the existing bounded IO batch is active');
  valid = false; batch.resolve(); await scan;
  assert.equal(c.record.stats.length, 8, 'leaving the page stops before the next batch');
  assert.equal(c.record.primed.length, 0); assert.equal(c.record.invalidated.length, 0);
  assert.equal(c.record.flushed, 0); assert.equal(c.store.items.size, 24, 'partial scan does not invalidate unvisited aliases');

  const d = fixture(); await d.store.enforceLimit(1000);
  assert.equal(d.record.stats.length, 24); assert.equal(d.record.primed[0].length, 24);
  assert.equal(d.record.flushed, 1, 'unscoped startup/explicit maintenance keeps its normal behavior');

  const e = fixture(); valid = true; e.record.onUnlink = () => { valid = false; };
  await e.store.enforceLimit(1, () => valid);
  assert.equal(e.record.removed.length, 1, 'an unlink already in flight completes, then eviction stops');
  assert.equal(e.record.invalidated.length, 1); assert.equal(e.record.primed.length, 0);
  assert.equal(e.record.flushed, 0);
  console.log('PASS thumbnail maintenance: queued/mid-scan/mid-eviction cancellation, bounded IO, intact aliases and normal maintenance');
})().catch(error => { console.error(error); process.exitCode = 1; });

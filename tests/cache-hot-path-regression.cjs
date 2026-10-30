// Execute the production completion and storage-entry methods. Large thumbnail
// inventories must never sit between an original download and its display.
const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const exportsObject = {};
let cached = '', usage = 0, scanned = 0, physicalReads = 0, context = { cacheDir: '/cache' };
vm.runInNewContext(ts.transpileModule('export class Page {\n' +
  ['ensureCachedFile', 'openStorageSettings', 'refreshCacheUsage'].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, console, getContext: () => context,
  CacheManager: { findExisting: () => cached }, StorageBudget: { usage: () => usage,
    scan: () => { scanned++; return usage; }, thumbnailAllowance: () => 512,
    persistentUsage: () => { physicalReads++; return 400; } } });
const tick = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
(async () => {
  const page = new exportsObject.Page(), downloads = [];
  const progress = () => {}, valid = () => true, cancellation = {};
  Object.assign(page, {
    cacheDirectory: '/cache', cacheLimitBytes: 1000, cacheUsageBytes: 0,
    isVideo: () => false, originalCacheKey: e => 'scope:' + e.path,
    async ensureCacheState() {},
    async refreshCacheUsage() { throw Error('full inventory forbidden on download completion'); },
    repository: { async download(...args) { downloads.push(args); usage += 10; return '/cache/' + args[0].name; } }
  });
  for (let i = 0; i < 12; i++) {
    const entry = { path: '/photos/' + i, name: i + '.jpg' };
    assert.equal(await page.ensureCachedFile(entry, progress, valid, cancellation), '/cache/' + entry.name);
    assert.equal(page.cacheUsageBytes, usage, 'completion reads the already-maintained byte counter');
  }
  assert.equal(downloads.length, 12);
  assert.equal(downloads[0][1], '/cache'); assert.equal(downloads[0][2], 1000);
  assert.equal(downloads[0][3], progress); assert.equal(downloads[0][4], valid);
  assert.equal(downloads[0][5], cancellation, 'progress, cancellation and quota still reach the real writer');
  cached = '/cache/existing.jpg'; const events = [];
  assert.equal(await page.ensureCachedFile({ path: '/photos/cached', name: 'cached.jpg' }, e => events.push(e)), cached);
  assert.equal(downloads.length, 12); assert.equal(events[0].receiveSize, 1);
  cached = '';
  page.repository.download = async () => { throw Error('download failed'); };
  await assert.rejects(page.ensureCachedFile({ path: '/photos/failure', name: 'failure.jpg' }), /download failed/);
  assert.equal(page.cacheUsageBytes, 120, 'a failed download cannot invent a successful cache size');

  let refreshed = 0, release;
  page.screen = 'settings'; page.isBusy = false; page.storageUsageRefreshToken = 0;
  page.ensureCacheState = () => new Promise(resolve => { release = resolve; });
  page.refreshCacheUsage = exportsObject.Page.prototype.refreshCacheUsage;
  page.repository.enforceThumbnailCacheLimit = async () => { refreshed++; };
  page.updateTopTitle = () => {}; page.updateBottomBarVisibility = () => {};
  page.openStorageSettings(); assert.equal(page.showStorageSettings, true);
  assert.equal(refreshed, 0, 'storage inspection waits for initialization');
  release(); await tick(); assert.equal(refreshed, 1, 'explicit storage inspection still refreshes physical usage');
  page.screen = 'files'; page.openStorageSettings(); await tick(); assert.equal(refreshed, 1);

  page.screen = 'settings'; page.openStorageSettings(); page.screen = 'files'; release(); await tick();
  assert.equal(refreshed, 1, 'leaving before initialization prevents the full scan'); assert.equal(scanned, 1);

  let finishScan, scanValid;
  page.ensureCacheState = async () => {};
  page.repository.enforceThumbnailCacheLimit = async (_limit, valid) => {
    scanValid = valid; refreshed++; await new Promise(resolve => finishScan = resolve);
  };
  page.screen = 'settings'; page.openStorageSettings(); await tick(); assert.equal(scanValid(), true);
  page.showStorageSettings = false; assert.equal(scanValid(), false, 'in-flight inventory observes page exit');
  finishScan(); await tick(); assert.equal(physicalReads, 1, 'cancelled inventory cannot trigger a late full physical-usage walk');

  page.repository.enforceThumbnailCacheLimit = async () => { refreshed++; };
  page.ensureCacheState = () => new Promise(resolve => { release = resolve; });
  page.openStorageSettings(); const firstRelease = release;
  page.showStorageSettings = false; page.openStorageSettings(); const secondRelease = release;
  const prior = refreshed; firstRelease(); secondRelease(); await tick();
  assert.equal(refreshed, prior + 1, 'reopening cannot revive the previous storage request');
  console.log('PASS original completion: no full thumbnail inventory; live byte count, quota/cancel propagation, cache hits/failures and explicit storage refresh');
})().catch(error => { console.error(error); process.exitCode = 1; });

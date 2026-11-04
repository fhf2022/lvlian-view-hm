// Run real page methods after retiring the R2/A3 experiment alternatives.
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
class UgreenError extends Error { constructor(status) { super('request'); this.status = status; } }
vm.runInNewContext(ts.transpileModule('export class Page {\n' +
  ['notifyEntryChanged', 'trimViewerOriginalState', 'loadViewerOriginal'].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, console, STATE_TRACE: false, THUMB_PROBE: false,
  ImageRotateOrientation: { AUTO: 'auto' }, UgreenError, CacheManager: { findExisting: () => '' } });
const Page = exportsObject.Page;
for (const surface of [undefined, 'list', 'grid', 'waterfall']) {
  const p = new Page(), calls = [];
  p.fileEntryDataSource = { indexOfPath: path => path === 'a' ? 3 : -1,
    notifyItemChanged: index => calls.push('file:' + index) };
  p.waterfallDataSource = { indexOfPath: path => path === 'a' ? 5 : -1,
    notifyItemChanged: index => calls.push('waterfall:' + index) };
  for (const key of ['entries', 'waterfallEntries']) {
    Object.defineProperty(p, key, { get() { throw Error('root array must not be read'); },
      set() { throw Error('root array must not be replaced'); } });
  }
  p.notifyEntryChanged('a', surface);
  assert.deepEqual(calls, surface === 'waterfall' ? ['waterfall:5'] :
    surface === undefined ? ['file:3', 'waterfall:5'] : ['file:3']);
  calls.length = 0; p.notifyEntryChanged('missing', surface); assert.equal(calls.length, 0);
}
{
  const p = new Page(), retired = [], states = {}, finished = [];
  Object.assign(p, { viewerImages: ['a', 'b', 'c', 'd'].map(path => ({ path })),
    viewerImageIndex: 1, viewerPendingIndex: 2, viewerActiveLoadPaths: { a: true },
    viewerOriginalBitmaps: { a: {}, b: {}, c: {}, d: {} }, viewerOriginalLocalPaths: { d: 'old' },
    viewerProgressLastUpdateAt: { a: 1, b: 2, c: 3, d: 4 },
    viewerLoadRequests: { a: true, b: true, c: true, d: true },
    viewerLoadQueue: ['b', 'c', 'd'].map(path => ({ path })), cleanupRequests: 0,
    tryEnqueueViewerCleanupItem(record, path, kind) { retired.push([path, kind]); },
    removeViewerBitmap(store, path) { delete store[path]; },
    requestViewerCleanup() { this.cleanupRequests++; },
    updateImageVisualState(path, update) { states[path] = {}; update(states[path]); },
    finishViewerOriginalLoading(path, failed) { finished.push([path, failed]); }
  });
  p.trimViewerOriginalState();
  assert.deepEqual(Object.keys(p.viewerOriginalBitmaps), ['a', 'b', 'c'], 'active load lease survives trim');
  assert.deepEqual(retired, [['d', 'original']], 'retired raster goes through deferred cleanup');
  assert.equal(p.viewerOriginalLocalPaths.d, ''); assert.equal(p.cleanupRequests, 1);
  assert.equal(states.d.visibleLayer, 'thumbnail'); assert.equal(states.d.originalUri, '');
  assert.deepEqual(Object.keys(p.viewerProgressLastUpdateAt), ['b', 'c']);
  assert.deepEqual(Array.from(p.viewerLoadQueue, item => item.path), ['b', 'c']);
  assert.deepEqual(Object.keys(p.viewerLoadRequests), ['a', 'b', 'c']);
  assert.deepEqual(finished, [['d', false]]);
  p.viewerActiveLoadPaths.a = false; p.trimViewerOriginalState();
  assert.deepEqual(Object.keys(p.viewerOriginalBitmaps), ['b', 'c'], 'finished old lease is retired next trim');
}
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject }; }
async function tick() { for (let i = 0; i < 6; i++) await Promise.resolve(); }
function loadingPage() {
  const p = new Page(), download = deferred(), decode = deferred();
  Object.assign(p, { showImageViewer: true, viewerGeneration: 7, viewerPrimaryPath: 'a',
    viewerManualLoadPaths: {}, viewerLoadRequests: { a: true }, viewerActiveLoadPaths: { a: true },
    viewerActiveLoads: 1, viewerImageEntry: { path: 'a' }, viewerClosePending: false,
    decoded: 0, committed: 0, trimmed: 0, drained: 0, requeued: 0,
    ensureCacheState: async () => {}, originalCacheKey: entry => entry.path,
    shouldAutoLoadViewerOriginal: () => true, viewerContainsPath: () => true,
    viewerPrefetchCoordinator: { downloadCurrentOriginal: () => download.promise },
    decodeViewerOriginalBitmap() { this.decoded++; return decode.promise; },
    updateViewerDownloadProgress() {}, setViewerDownloadProgress() {}, finishViewerOriginalLoading() {},
    applyDecodedBitmapGeometry() {}, commitViewerBitmap() { this.committed++; },
    trimViewerOriginalState() { this.trimmed++; }, drainViewerLoadQueue() { this.drained++; },
    enqueueViewerOriginal() { this.requeued++; }
  });
  return { p, download, decode };
}
(async () => {
  let t = loadingPage();
  let job = t.p.loadViewerOriginal({ path: 'a', name: 'a.jpg' }, 7);
  await tick(); t.p.viewerPrimaryPath = 'b'; t.download.resolve('/cache/a'); await job;
  assert.equal(t.p.decoded, 0, 'obsolete download must not start native decode');
  assert.equal(t.p.committed, 0); assert.equal(t.p.trimmed, 1); assert.equal(t.p.viewerActiveLoads, 0);
  t = loadingPage(); job = t.p.loadViewerOriginal({ path: 'a', name: 'a.jpg' }, 7);
  await tick(); t.download.resolve('/cache/a'); await tick(); assert.equal(t.p.decoded, 1);
  t.p.viewerPrimaryPath = 'b'; t.decode.resolve({ bitmap: {} }); await job;
  assert.equal(t.p.committed, 0, 'obsolete decode cannot replace the visible page');
  for (const change of [p => { p.showImageViewer = false; }, p => { p.viewerGeneration++; }]) {
    t = loadingPage(); job = t.p.loadViewerOriginal({ path: 'a', name: 'a.jpg' }, 7);
    await tick(); change(t.p); t.download.resolve('/cache/a'); await job;
    assert.equal(t.p.decoded, 0); assert.equal(t.p.committed, 0);
  }
  t = loadingPage(); job = t.p.loadViewerOriginal({ path: 'a', name: 'a.jpg' }, 7);
  await tick(); t.download.resolve('/cache/a'); await tick(); t.decode.resolve({ bitmap: {} }); await job;
  assert.equal(t.p.committed, 1); assert.equal(t.p.viewerActiveLoads, 0); assert.equal(t.p.drained, 1);
  t = loadingPage(); job = t.p.loadViewerOriginal({ path: 'a', name: 'a.jpg' }, 7);
  await tick(); t.download.reject(new UgreenError(499)); await job;
  assert.equal(t.p.requeued, 1, 'still-visible cancellation may be readmitted');
  assert.doesNotMatch(source, /EXPERIMENT_(?:R2_THUMB_CELL|R2_WATERFALL_CELL|GRID_BLANK|GRID_FIXED_SOURCE|GRID_SOURCE_SIZE|A3_SINGLE_ORIGINAL_VIEWER|GRID_CACHED_COUNT|GRID_SOURCE_SAFE)/);
  assert.match(source, /const GRID_CACHED_ROW_COUNT: number = 4/);
  assert.match(source, /\.cachedCount\(GRID_CACHED_ROW_COUNT\)/);
  console.log('PASS image production policy: local updates, native raster lease/deferred cleanup, stale download/decode/close guards, cancellation and fixed stable configuration');
})().catch(error => { console.error(error); process.exitCode = 1; });

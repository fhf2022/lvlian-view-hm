// node tests/viewer-prefetch-regression.cjs <SDK typescript.js>
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.argv[2]);
const cache = new Map(), timers = new Map(); let timerId = 0;
function load(name) {
  if (cache.has(name)) return cache.get(name);
  if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
  const exports = {}; cache.set(name, exports);
  const code = ts.transpileModule(fs.readFileSync('entry/src/main/ets/' + name + '.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true }
  }).outputText;
  vm.runInNewContext(code, { exports, console, Observed: c => c,
    setTimeout(fn) { timers.set(++timerId, fn); return timerId; }, clearTimeout(id) { timers.delete(id); },
    require(key) { return load(key.startsWith('.') ? path.posix.normalize(path.posix.join(path.posix.dirname(name), key)) : key); }
  });
  return exports;
}
const { ViewerPrefetchCoordinator } = load('media/ViewerPrefetchCoordinator');
const { FileEntry } = load('model/FileEntry');
const { UgreenError, UgreenErrorKind } = load('ugreen/UgreenErrors');
const tick = async () => { for (let i = 0; i < 15; i++) await Promise.resolve(); };
async function idle() { const fns = [...timers.values()]; timers.clear(); fns.forEach(f => f()); await tick(); }
function make(options = {}) {
  timers.clear();
  const images = Array.from({ length: 9 }, (_, i) => Object.assign(new FileEntry(), {
    name: 'image-' + i + '.jpg', path: '/photos/' + i, size: 8e6, modifiedTime: 1
  }));
  const h = { images, active: true, busy: false, auto: true, limit: 2, scope: 'A', started: [], cached: new Set(), ready: [], max: 0, activeTransfers: 0 };
  h.key = entry => h.scope + ':' + entry.path + ':' + entry.modifiedTime;
  const delegate = {
    isViewerActive: () => h.active, isInteractionBusy: () => h.busy,
    shouldAutoPrefetch: () => h.auto, maxConcurrentDownloads: () => h.limit,
    fileKey: h.key, isFileCached: entry => h.cached.has(h.key(entry)),
    async onOriginalFileReady(entry) { h.ready.push(entry.path); },
    downloadOriginalFile(entry, progress, guard, signal) {
      let resolve, reject;
      const promise = new Promise((a, b) => { resolve = a; reject = b; });
      h.max = Math.max(h.max, ++h.activeTransfers);
      const key = h.key(entry);
      const job = { entry, progress, guard, signal, aborted: false,
        complete() { assert.ok(guard(), 'only wanted transfers may publish a completed file'); h.cached.add(key); resolve('/cache/' + entry.name); },
        fail() { reject(new Error('server unavailable')); },
        finishAbort() { reject(new UgreenError(UgreenErrorKind.NETWORK, 'cancelled', 499)); }
      };
      const off = signal.subscribe(() => { job.aborted = true; if (!options.delayAbort) job.finishAbort(); });
      h.started.push(job);
      return promise.finally(() => { off(); h.activeTransfers--; });
    }
  };
  h.c = new ViewerPrefetchCoordinator(delegate);
  h.c.onViewerOpened(0, images);
  return h;
}
async function preload(h, index = 0) {
  h.c.onCurrentOriginalRevealed(h.images[index].path);
  await tick(); assert.equal(h.started.length, 0, 'idle gate must not launch early');
  await idle();
}
(async () => {
  let h = make(); await preload(h);
  assert.deepEqual(h.started.map(j => j.entry.path), ['/photos/1', '/photos/2']);
  assert.equal(h.max, 2);
  h.started[0].complete(); await tick();
  assert.equal(h.started.length, 2, 'n+3 must not be queued when a slot frees');
  h.started[1].complete(); await tick(); assert.equal(h.activeTransfers, 0);

  h = make(); await preload(h);
  const promoted = h.started[0]; let progress = 0;
  h.c.onViewerIndexChanged(1, h.images);
  const current = h.c.downloadCurrentOriginal(h.images[1], () => progress++, false);
  await tick(); assert.equal(h.started.length, 2); assert.equal(promoted.aborted, false);
  promoted.progress({ receiveSize: 100, totalSize: 200 }); assert.equal(progress, 1);
  promoted.complete(); await current; await tick();
  h.c.onCurrentOriginalRevealed(h.images[1].path); await idle();
  assert.deepEqual(h.started.map(j => j.entry.path), ['/photos/1', '/photos/2', '/photos/3']);
  assert.equal(h.started[1].aborted, false, 'still-ahead task survives promotion of its neighbour');
  h.c.onViewerClosed(); await tick(); assert.equal(h.activeTransfers, 0);

  h = make(); await preload(h);
  h.c.onViewerIndexChanged(5, h.images);
  const jump = h.c.downloadCurrentOriginal(h.images[5], () => {}, false);
  await tick(); assert.ok(h.started.slice(0, 2).every(j => j.aborted));
  assert.equal(h.started[2].entry.path, '/photos/5');
  h.started[2].complete(); await jump;
  h.c.onCurrentOriginalRevealed(h.images[5].path); await idle();
  h.c.onViewerIndexChanged(4, h.images);
  const reverse = h.c.downloadCurrentOriginal(h.images[4], () => {}, false);
  await tick(); const reverseJob = h.started.at(-1); assert.equal(reverseJob.entry.path, '/photos/4');
  reverseJob.complete(); await reverse;
  h.c.onCurrentOriginalRevealed(h.images[4].path); await idle();
  assert.deepEqual(h.started.slice(-2).map(j => j.entry.path), ['/photos/3', '/photos/2']);
  assert.equal(h.max, 2); h.c.onViewerClosed(); await tick();

  h = make(); h.limit = 1; await preload(h);
  assert.equal(h.started.length, 1); h.started[0].complete(); await tick();
  assert.equal(h.started.length, 2); assert.equal(h.max, 1);
  h.c.onViewerClosed(); await tick();
  h = make(); h.auto = false; await preload(h); assert.equal(h.started.length, 0);
  const manual = h.c.downloadCurrentOriginal(h.images[0], () => {}, true); await tick();
  assert.equal(h.started.length, 1); h.started[0].complete(); await manual;
  h.c.onCurrentOriginalRevealed(h.images[0].path); await idle(); assert.equal(h.started.length, 1);

  h = make(); await preload(h); h.started[0].fail(); h.started[1].fail(); await tick();
  assert.equal(h.started.length, 2, 'background failures must not produce an immediate retry loop');
  h.c.onViewerIndexChanged(1, h.images);
  const retry = h.c.downloadCurrentOriginal(h.images[1], () => {}, false); await tick();
  assert.equal(h.started.length, 3); h.started[2].complete(); await retry;

  h = make({ delayAbort: true }); await preload(h);
  const old = h.started[0]; h.c.onViewerClosed();
  h.c.onViewerOpened(1, h.images);
  const reopened = h.c.downloadCurrentOriginal(h.images[1], () => {}, false);
  await tick(); assert.equal(h.started.length, 2, 'do not reuse an occupied slot or a cancelling .part writer');
  old.finishAbort(); await tick();
  assert.equal(h.started.length, 3); assert.equal(h.started[2].entry.path, '/photos/1');
  h.started[2].complete(); await reopened;
  h.started[1].finishAbort(); await tick(); assert.equal(h.max, 2);

  h = make(); await preload(h); h.busy = true; h.c.onUserInteraction();
  h.started[0].complete(); await tick(); assert.equal(h.ready.length, 0, 'no neighbour geometry work during interaction');
  assert.equal(h.started.length, 2); h.c.onViewerClosed(); await tick();
  h = make(); h.c.onViewerIndexChanged(8, h.images); h.c.onCurrentOriginalRevealed(h.images[8].path);
  await idle(); assert.equal(h.started.length, 0, 'end of folder is bounded');
  h.c.onViewerIndexChanged(0, h.images); h.c.onCurrentOriginalRevealed(h.images[0].path);
  await idle(); assert.equal(h.started.length, 0, 'reverse start of folder is bounded');

  h = make(); await preload(h); h.scope = 'B'; h.c.onViewerIndexChanged(1, h.images);
  const otherAccount = h.c.downloadCurrentOriginal(h.images[1], () => {}, false);
  await tick(); assert.ok(h.started.slice(0, 2).every(j => j.aborted));
  h.started.at(-1).complete(); await otherAccount; assert.equal(h.max, 2);
  h.c.onViewerClosed(); await tick();

  // Exercise real HTTP cancellation while no headers or bytes arrive.
  const { DownloadCancellation } = load('core/network/DownloadCancellation');
  let destroyed = 0, requested = 0, rejectRequest;
  cache.set('@kit.NetworkKit', { http: { RequestMethod: { GET: 0 }, createHttp() {
    return { on() {}, off() {}, destroy() { destroyed++; rejectRequest?.(new Error('destroyed')); },
      requestInStream() { requested++; return new Promise((_resolve, reject) => { rejectRequest = reject; }); } };
  } } });
  cache.set('@kit.CoreFileKit', { fileIo: {} });
  cache.set('@kit.ArkTS', { util: {} });
  cache.set('download/StorageBudget', { StorageBudget: { pin() {}, unpin() {} } });
  cache.set('core/network/NasConnection', { NasConnection: { shared: () => ({ begin: () => 1 }) } });
  const { HttpTransport } = load('core/network/HttpTransport');
  const signal = new DownloadCancellation();
  const stalled = new HttpTransport().requestBinaryToFile('https://nas/file', '/cache/stalled', {}, 0, 1, undefined, undefined, '', signal);
  await tick(); assert.equal(requested, 1); signal.cancel();
  await assert.rejects(stalled, error => error.status === 499);
  const afterCancellation = destroyed; signal.cancel(); assert.equal(destroyed, afterCancellation);
  const beforeStart = new DownloadCancellation(); beforeStart.cancel();
  await assert.rejects(new HttpTransport().requestBinaryToFile('https://nas/file', '/cache/stalled', {}, 0, 1, undefined, undefined, '', beforeStart), error => error.status === 499);
  assert.equal(requested, 1, 'a pre-cancelled operation cannot start a request');
  console.log('PASS: two-ahead window, total concurrency, promotion, reverse/jump, metered/manual, bounded failures, stalled cancellation ownership, interaction and account isolation');
})().catch(error => { console.error(error); process.exitCode = 1; });

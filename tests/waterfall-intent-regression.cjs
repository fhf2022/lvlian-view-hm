// Replay real coordinator/loader code with controlled asynchronous responses.
const assert = require('node:assert/strict'), fs = require('node:fs');
const vm = require('node:vm'), path = require('node:path'), ts = require(process.argv[2]);
const modules = new Map();
function load(name) {
  if (modules.has(name)) return modules.get(name);
  const exports = {}; modules.set(name, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/' + name + '.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true }
  }).outputText, { exports, console, Observed: c => c,
    require: key => load(path.posix.normalize(path.posix.join(path.posix.dirname(name), key))) });
  return exports;
}
const { WaterfallBatchCoordinator: Coordinator } = load('media/WaterfallBatchCoordinator');
const { WaterfallOriginalLoader: Loader } = load('media/WaterfallOriginalLoader');
const { FileEntry } = load('model/FileEntry');
const tick = async () => { for (let i = 0; i < 180; i++) await Promise.resolve(); };
const deferred = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
function fixture() {
  const h = { gate: null, fail: false, calls: [], published: [], evicted: [], targets: [], active: 0, peak: 0 };
  h.entries = Array.from({ length: 240 }, (_, i) => Object.assign(new FileEntry(), { path: '/image/' + i }));
  h.coordinator = new Coordinator({
    async geometry(entry, valid) {
      h.calls.push(entry.path); h.peak = Math.max(h.peak, ++h.active);
      try {
        if (h.gate) await h.gate;
        if (!valid()) throw Error('cancelled');
        if (h.fail && Number(entry.path.split('/').at(-1)) >= 72) throw Error('offline');
        return { displayWidth: 1000, displayHeight: 1500 };
      } finally { h.active--; }
    },
    async thumbnail() {}, changed() {},
    publish(change) { h.published.push({ change, first: h.coordinator.first }); },
    originals(entries) { h.targets = entries; h.loader?.update(entries); },
    evict(entries) { h.evicted.push(...entries.map(e => e.path)); }
  });
  return h;
}
(async () => {
  const a = fixture(); a.coordinator.reset(a.entries); await tick();
  const first = deferred(); a.gate = first.promise;
  const obsolete = a.coordinator.ensure(73); await tick();
  await a.coordinator.ensure(1); first.resolve(); await obsolete; await tick();
  assert.equal(a.coordinator.first, 0); assert.equal(a.coordinator.focus, 0);
  assert.ok(a.published.every(p => p.first === 0), 'an older cold result cannot publish over a newer cached selection');
  assert.ok(a.peak <= 2, 'cancelled geometry holds its physical slots until cleanup');

  const b = fixture(); b.coordinator.reset(b.entries); await tick();
  const blocked = deferred(); b.gate = blocked.promise;
  const old = b.coordinator.ensure(73); await tick(); const latest = b.coordinator.ensure(121);
  blocked.resolve(); await old; await latest; await tick();
  assert.deepEqual(b.published.map(p => p.first), [0, 10], 'superseded cold destinations never flash an intermediate surface');

  // Cancel and reselect the same group before queued work starts. Each task
  // must retain its own cancellation signal instead of borrowing a newer one.
  const same = fixture(); same.coordinator.reset(same.entries); await tick();
  const sameGate = deferred(); same.gate = sameGate.promise;
  const one = same.coordinator.ensure(73); const two = same.coordinator.ensure(121);
  const three = same.coordinator.ensure(73); sameGate.resolve(); await Promise.all([one, two, three]); await tick();
  assert.deepEqual(same.published.map(p => p.first), [0, 6]);

  const c = fixture(); c.coordinator.reset(c.entries); await tick(); c.fail = true;
  await c.coordinator.ensure(73); await tick(); const failedCalls = c.calls.length;
  for (let i = 0; i < 5; i++) {
    c.coordinator.visible(0, 11); c.coordinator.sync(c.entries);
    c.coordinator.setHidden(true); c.coordinator.setHidden(false); await tick();
  }
  assert.equal(c.calls.length, failedCalls, 'passive visibility/sync/foreground events do not replay a failed request');
  assert.equal(c.coordinator.error, true);
  c.fail = false; c.coordinator.retry(); await tick();
  assert.equal(c.coordinator.first, 6); assert.equal(c.coordinator.error, false, 'explicit retry recovers the requested destination');

  const initial = fixture(); initial.fail = true; initial.coordinator.reset(initial.entries, 73); await tick();
  const initialCalls = initial.calls.length;
  for (let i = 0; i < 5; i++) { initial.coordinator.sync(initial.entries); await tick(); }
  assert.equal(initial.calls.length, initialCalls, 'a failed initial group also stays failed until an explicit action');
  initial.fail = false; initial.coordinator.retry(); await tick(); assert.equal(initial.coordinator.first, 6);

  const d = fixture(), jobs = [];
  d.loader = new Loader({ fileKey: e => e.path,
    download(entry, valid, signal) { const gate = deferred(); jobs.push({ entry, signal, finish: () => gate.resolve('/cache/' + entry.path) }); return gate.promise; },
    async ready() {}, finished(entry, success) { d.coordinator.originalFinished(entry, success); }
  });
  d.coordinator.reset(d.entries); await tick();
  for (let group = 1; group < 4; group++) {
    d.coordinator.edge(1); await tick(); d.coordinator.visible(group * 12, group * 12 + 11);
  }
  assert.equal(jobs.length, 2); await d.coordinator.ensure(121); await tick();
  assert.deepEqual(Array.from(d.coordinator.residentGroups()), [10]);
  assert.ok(d.targets.every(e => Number(e.path.split('/').at(-1)) >= 120));
  assert.equal(d.evicted.length, 48, 'far replacement releases all four old groups');
  assert.ok(jobs[0].signal.isCancelled() && jobs[1].signal.isCancelled());
  jobs[0].finish(); jobs[1].finish(); await tick();
  assert.equal(jobs.length, 4); assert.ok(jobs.slice(2).every(j => Number(j.entry.path.split('/').at(-1)) >= 120));
  d.loader.reset(); jobs[2].finish(); jobs[3].finish(); await tick();
  console.log('PASS waterfall latest intent: cached/cold/same-group reselection, physical cancellation, bounded failure retry and far-window download cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });

// node tests/grid-window-reflow-regression.cjs <SDK typescript.js>
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]), source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const a = source.indexOf('  private gridLayoutWindowSize ='), b = source.indexOf('  private gridViewportAnchor:', a);
assert.ok(a > 0 && b > a);
let getWindow = () => Promise.resolve({ on() {} });
const exp = {};
vm.runInNewContext(ts.transpileModule('export class H {' + source.slice(a, b) +
  ['recordFilePageSize', 'observeGridLayoutSize'].map(method).join('\n') + '}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exp, window: { getLastWindow: () => getWindow() }, getContext: () => ({}),
  EXPERIMENT_GRID_CACHED_COUNT: 4, THUMB_PROBE: false, ImageRotateOrientation: { UP: 0 } });
(async () => {
  for (const density of [1, 2, 3]) {
    const h = new exp.H(), changes = [], events = new Map();
    Object.assign(h, { gridLayoutWatching: false, pageWidthVp: 400, pageHeightVp: 800,
      getUIContext: () => ({ px2vp: value => value / density }),
      updateFilePageSize: (width, height) => changes.push([width, height]) });
    const win = { on(name, callback) { events.set(name, callback); } };
    getWindow = () => Promise.resolve(win);
    h.observeGridLayoutSize(); await Promise.resolve();
    assert.equal(h.gridLayoutWindow, win);
    const callback = events.get('windowSizeChange'); assert.equal(typeof callback, 'function');
    callback({ width: 1400 * density, height: 900 * density });
    assert.deepEqual(changes, [[1400, 900]], 'resize is dispatched synchronously, before another render frame');
    h.recordFilePageSize({ width: 1400, height: 900 });
    assert.deepEqual(changes.at(-1), [1400, 900], 'area fallback uses the same size/anchor implementation');
    callback({ width: 0, height: 900 }); assert.equal(changes.length, 2);
    h.gridLayoutWatching = false; callback({ width: 900 * density, height: 1400 * density });
    assert.equal(changes.length, 2, 'late native events cannot update a destroyed page');
  }
  const h = new exp.H(), listeners = [];
  let resolveWindow;
  getWindow = () => new Promise(resolve => { resolveWindow = resolve; });
  h.observeGridLayoutSize(); h.gridLayoutWatching = false;
  resolveWindow({ on: (...args) => listeners.push(args) }); await Promise.resolve();
  assert.equal(listeners.length, 0, 'closing before window lookup completes does not leak a listener');
  assert.match(source, /off\('windowSizeChange', this.gridLayoutWindowSize\)/);
  assert.doesNotMatch(source, /gridLayoutRotation|before-window/);
  assert.doesNotMatch(source, /gridLayoutChanging|gridReflowDecodedUris|GridThumbnailRetention|RetainedGridThumbnailView/);
  console.log('PASS: window reflow — shared synchronous sizing, density conversion and listener lifetime; no premature rotation layout');
})().catch(e => { console.error(e); process.exitCode = 1; });

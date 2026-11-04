// Replay SDK-generated callbacks: metadata can arrive after the native Image.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const file = process.argv[3] || 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/components/WaterfallThumbnailCell.ts';
const source = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
const node = source.statements.find(n => ts.isClassDeclaration(n) &&
  ['WaterfallThumbnailCell', 'WaterfallThumbCell'].includes(n.name?.text));
assert.ok(node, 'compiled waterfall thumbnail cell');
let callbacks = [], attributes = {}, stateObjects = new Set();
const native = name => new Proxy({}, { get: (_, method) => value => { attributes[name + '.' + method] = value; } });
const Image = native('Image'), Stack = native('Stack'), LoadingProgress = native('LoadingProgress'), Text = native('Text');
const If = { create() {}, pop() {} };
class ViewPU {
  finalizeConstruction() {}
  observeComponentCreation2(callback, type) { callbacks.push({ callback, type }); callback(callbacks.length, true); }
  ifElseBranchUpdateFunction(_branch, callback) { callback(); }
}
class SynchedPropertyNesedObjectPU {
  constructor(value) { this.value = value; } get() { return this.value; } set(value) { this.value = value; }
}
class WaterfallImageState {}
class WaterfallThumbnailBridge {}
class WaterfallThumbBridge {}
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(node.getText(source) + '\nexport { ' + node.name.text + ' as Cell };', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exportsObject, ViewPU, SynchedPropertyNesedObjectPU, WaterfallImageState,
  WaterfallThumbnailBridge, WaterfallThumbBridge, Image, Stack, LoadingProgress, Text, If,
  Alignment: { Center: 'center' }, ImageFit: { Contain: 'contain' }, ObservedObject: { GetRawObject: v => v } });
function make(next) {
  callbacks = []; attributes = {}; stateObjects = new Set();
  const entry = { path: '/photos/1.jpg', previewRevision: 0 }, completed = [], errors = [];
  const bridge = {
    resolveInto(_entry, state) { stateObjects.add(state); Object.assign(state, next); return state; },
    onComplete(...args) { completed.push(args); }, onError(value) { errors.push(value); }
  };
  const h = new exportsObject.Cell(null, { entry, bridge, index: 8 }); h.initialRender();
  return { entry, completed, errors, change(value) { Object.assign(next, value); entry.previewRevision++; },
    image: () => callbacks.filter(x => x.type === Image).at(-1).callback,
    ifs: () => callbacks.filter(x => x.type === If).map(x => x.callback) };
}
let t = make({ available: true, aspectReady: false, source: 'file://thumb', orientation: 'auto',
  transitionId: '', syncLoad: false, failed: false });
assert.equal(attributes['Image.opacity'], 0, 'never show a provisional square raster');
assert.equal(attributes['LoadingProgress.width'], 24);
assert.equal(attributes['Stack.clip'], true); assert.equal(attributes['Stack.borderRadius'], 10);
assert.equal(stateObjects.size, 1, 'all source queries reuse the cell-owned state object');
t.change({ source: 'file://original', orientation: 'up', transitionId: 'return-path', syncLoad: true });
attributes = {}; t.image()(100, false);
assert.equal(attributes['Image.create'], 'file://original');
assert.equal(attributes['Image.orientation'], 'up');
assert.equal(attributes['Image.geometryTransition'], 'return-path');
assert.equal(attributes['Image.syncLoad'], true);
assert.equal(attributes['Image.sourceSize'], undefined, 'metadata must not seed a square decode size');
attributes['Image.onComplete']({ width: 800, height: 1200 }); attributes['Image.onError']();
assert.equal(t.completed[0][0], t.entry); assert.equal(t.completed[0][1], 8);
assert.equal(t.errors[0], t.entry);
const [outer, aspect, loading] = t.ifs();
t.change({ aspectReady: true }); attributes = {}; aspect(101, false); loading(102, false);
assert.equal(attributes['Image.opacity'], 1, 'actual aspect unlocks the native Image');
assert.equal(attributes['LoadingProgress.create'], undefined, 'ready image removes the loading branch');
const bitmap = { borrowed: true }; t.change({ source: bitmap, transitionId: '', syncLoad: false });
attributes = {}; t.image()(103, false);
assert.equal(attributes['Image.create'], bitmap); assert.equal(attributes['Image.geometryTransition'], '');
assert.equal(attributes['Image.syncLoad'], false); assert.equal(stateObjects.size, 1);
t = make({ available: false, aspectReady: false, failed: false });
assert.equal(attributes['Image.create'], undefined); assert.equal(attributes['LoadingProgress.width'], 24);
const [missing, status] = t.ifs(); t.change({ failed: true }); attributes = {}; status(104, false);
assert.equal(attributes['Text.create'], '!'); assert.equal(attributes['LoadingProgress.create'], undefined);
t.change({ available: true, aspectReady: true, failed: false, source: 'file://recovered' });
attributes = {}; missing(105, false); status(106, false);
assert.equal(attributes['Image.create'], 'file://recovered'); assert.equal(attributes['Image.opacity'], 1);
console.log('PASS compiled waterfall thumbnail: metadata gating, placeholder/error/recovery, live source/transition updates, borrowed bitmap and one reusable state');

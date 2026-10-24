// Run after assembleHap: node this-file.cjs <typescript.js> [generated Index.ts].
// Exercise the actual compiled native Image update callbacks, including an
// update where only attributes change and no build()/lifecycle hook runs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const file = process.argv[3] || 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts';
const source = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
const node = source.statements.find(item => ts.isClassDeclaration(item) && item.name?.text === 'GridThumbCell');
assert.ok(node, 'compiled GridThumbCell');
let callbacks = [], attributes = {}, resolutions = 0;
const Image = new Proxy({}, { get: (_, name) => value => { attributes[name] = value; } });
const If = { create() {}, pop() {} };
class ViewPU {
  constructor() {}
  finalizeConstruction() {}
  observeComponentCreation2(callback, type) {
    callbacks.push({ callback, type }); callback(callbacks.length, true);
  }
  ifElseBranchUpdateFunction(_branch, callback) { callback(); }
}
class SynchedPropertyNesedObjectPU {
  constructor(value) { this.value = value; }
  get() { return this.value; }
  set(value) { this.value = value; }
}
class GridImageState {}
class GridThumbBridge {}
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(node.getText(source) + '\nexport { GridThumbCell };', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: exportsObject, ViewPU, SynchedPropertyNesedObjectPU,
  GridImageState, GridThumbBridge, Image, If, ImageFit: { Cover: 'cover', Contain: 'contain' },
  Visibility: { Hidden: 'hidden', Visible: 'visible' }, ObservedObject: { GetRawObject: value => value }
});

function make(sized, available = true) {
  callbacks = []; attributes = {}; resolutions = 0;
  const entry = { path: '/photos/image.jpg', previewRevision: 1 };
  let next = { available, source: 'file://first', sourceWidth: sized ? 512 : 0,
    sourceHeight: sized ? 384 : 0, orientation: 0, transitionId: '', syncLoad: false, hidden: false };
  let completed;
  const bridge = {
    resolveInto(_entry, state) { resolutions++; Object.assign(state, next); return state; },
    icon: () => 'placeholder', probeAppear() {},
    onComplete(...args) { completed = args; }, onError() {}
  };
  const h = new exportsObject.GridThumbCell(null, { entry, bridge, index: 7 });
  h.initialRender();
  return { h, entry, set: value => { next = { ...next, ...value }; entry.previewRevision++; },
    image: () => callbacks.filter(item => item.type === Image).at(-1).callback,
    outer: callbacks[0].callback, completed: () => completed };
}
for (const sized of [false, true]) {
  const t = make(sized);
  const update = t.image();
  t.set({ source: 'file://second', orientation: 2, transitionId: 'return-image',
    syncLoad: true, hidden: true, sourceWidth: sized ? 384 : 0, sourceHeight: sized ? 512 : 0 });
  resolutions = 0; attributes = {};
  update(100, false);
  assert.equal(resolutions, 1, 'one full resolution per native Image update');
  assert.equal(attributes.create, 'file://second');
  assert.equal(attributes.orientation, 2);
  assert.equal(attributes.geometryTransition, 'return-image');
  assert.equal(attributes.syncLoad, true);
  assert.equal(attributes.visibility, 'hidden');
  if (sized) assert.deepEqual(JSON.parse(JSON.stringify(attributes.sourceSize)), { width: 384, height: 512 });
  else assert.equal(attributes.sourceSize, undefined);
  const bitmap = { borrowed: true };
  t.set({ source: bitmap, orientation: 0, transitionId: '', syncLoad: false, hidden: false });
  update(100, false);
  assert.equal(attributes.create, bitmap, 'bitmap handoff must not reuse an older URI snapshot');
  assert.equal(attributes.visibility, 'visible');
  assert.equal(attributes.geometryTransition, '');
  attributes.onComplete({ width: 512, height: 384 });
  assert.equal(t.completed()[0], t.entry);
  assert.equal(t.completed()[1], 7);
}
const t = make(false, false);
assert.equal(attributes.create, 'placeholder');
t.set({ available: true, source: 'file://ready' });
t.outer(1, false);
assert.equal(attributes.create, 'file://ready', 'a ready preview must replace its placeholder');
console.log('Grid thumbnail compiled update regression passed');

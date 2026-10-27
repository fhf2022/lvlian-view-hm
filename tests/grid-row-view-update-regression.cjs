// Run after assembleHap: node this-file.cjs <SDK typescript.js>
// Replaying compiled callbacks catches values accidentally frozen by a row's ForEach.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const base = 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/';
function declaration(file, name) {
  const source = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  return source.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === name);
}
let callbacks = [], widths = [], created, updated;
class ViewPU {
  observeComponentCreation2(callback, type) { callbacks.push({ callback, type }); callback(callbacks.length, true); }
  updateStateVarsOfChildByElmtId(_id, params) { updated = params; }
  static create(child) { created = child; }
  finalizeConstruction() {}
  forEachUpdateFunction(_id, items, build, key) {
    this.keys ??= new Set();
    for (let i = 0; i < items.length; i++) {
      const id = key(items[i]);
      if (!this.keys.has(id)) { this.keys.add(id); build(items[i], i); }
    }
  }
}
class Property {
  constructor(value) { this.value = value; }
  get() { return this.value; }
  set(value) { this.value = value; }
  reset(value) { this.value = value; }
}
const common = { create() {}, pop() {}, width(value) { widths.push(value); }, onAppear() {}, onDisAppear() {} };
const FileGridLayout = { gap: 1, columns: width => width < 1000 ? 6 : 10 };
const page = declaration(base + 'pages/Index.ts', 'Index');
const methods = page.members.filter(n => ['FileGridInteractiveCell', 'fileGridColumnCount'].includes(n.name?.text));
assert.equal(methods.length, 2);
const exports1 = {};
vm.runInNewContext(ts.transpileModule('export class H extends ViewPU {' + methods.map(n => n.getText()).join('\n') + '}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exports1, ViewPU, __Common__: common, FileGridLayout,
  FileGridCell: class { constructor(_owner, params) { this.params = params; } } });
const h = new exports1.H(), entry = { path: '/photo/1' };
Object.assign(h, { pageWidthVp: 1440, pageHeightVp: 960, selectionMode: false,
  gridThumbnailComponentId: e => e.path, FileGridThumbnail() {} });
h.FileGridInteractiveCell(entry, 1);
assert.equal(created.params.selectionMode, false); assert.equal(widths.at(-1), 143.1);
h.selectionMode = true; h.pageWidthVp = 960;
for (const { callback } of callbacks) callback(1, false);
assert.equal(updated.selectionMode, true, 'existing cells must enter multi-select without being rebuilt');
assert.equal(widths.at(-1), 955 / 6, 'existing cells must resize after a column change');

const Row = { create() {}, pop() {}, width() {}, alignItems() {} }, ForEach = { create() {}, pop() {} };
const exports2 = {};
vm.runInNewContext(ts.transpileModule('export ' + declaration(base + 'components/FileGridRowView.ts', 'FileGridRowView').getText(), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exports2, ViewPU, SynchedPropertyNesedObjectPU: Property,
  EmptyRowCell() {}, Row, ForEach, FileGridLayout, VerticalAlign: { Top: 0 } });
callbacks = []; const built = [];
const row = { start: 10, entries: [{ path: '/photo/10' }, { path: '/photo/11' }] };
const view = new exports2.FileGridRowView(null, { row, cell: (e, i) => built.push([e.path, i]) });
view.initialRender();
row.entries = [...row.entries, { path: '/photo/12' }];
callbacks.find(c => c.type === ForEach).callback(2, false);
assert.equal(JSON.stringify(built), JSON.stringify([['/photo/10', 10], ['/photo/11', 11], ['/photo/12', 12]]),
  'filling a partial row must only add the new file cell');
console.log('Compiled row membership, retained-cell selection and resize updates passed');

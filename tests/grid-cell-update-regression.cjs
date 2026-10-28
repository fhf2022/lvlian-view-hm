// Run after assembleHap: node this-file.cjs <SDK typescript.js>
// Replay compiled callbacks to verify existing file cells keep their bindings on resize.
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
}

const common = { create() {}, pop() {}, width(value) { widths.push(value); }, transition() {}, onAppear() {}, onDisAppear() {} };
const FileGridLayout = { gap: 1, columns: width => width < 1000 ? 5 : 7 };
const page = declaration(base + 'pages/Index.ts', 'Index');
const methods = page.members.filter(n => ['FileGridInteractiveCell', 'fileGridColumnCount'].includes(n.name?.text));
assert.equal(methods.length, 2);
const exports1 = {};
vm.runInNewContext(ts.transpileModule('export class H extends ViewPU {' + methods.map(n => n.getText()).join('\n') + '}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exports1, ViewPU, __Common__: common, FileGridLayout, TransitionEffect: { IDENTITY: {} },
  FileGridCell: class { constructor(_owner, params) { this.params = params; } } });
const h = new exports1.H(), entry = { path: '/photo/1' };
Object.assign(h, { pageWidthVp: 1440, pageHeightVp: 960, selectionMode: false,
  gridThumbnailComponentId: e => e.path, FileGridThumbnail() {} });
h.FileGridInteractiveCell(entry, 1);
assert.equal(created.params.selectionMode, false); assert.equal(widths.at(-1), 1434 / 7);
h.selectionMode = true; h.pageWidthVp = 960;
for (const { callback } of callbacks) callback(1, false);
assert.equal(updated.selectionMode, true, 'existing cells must enter multi-select without being rebuilt');
assert.equal(widths.at(-1), 956 / 5, 'existing cells must resize after a column change');

console.log('Compiled retained-cell selection and viewport resize updates passed');

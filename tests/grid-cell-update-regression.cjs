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
const layoutModule = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/FileGridLayout.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: layoutModule });
const FileGridLayout = layoutModule.FileGridLayout;
const page = declaration(base + 'pages/Index.ts', 'Index');
const methods = page.members.filter(n => ['FileGridInteractiveCell', 'fileGridColumnCount',
  'gridEntryUsesFileTile'].includes(n.name?.text));
assert.equal(methods.length, 3);
const exports1 = {};
vm.runInNewContext(ts.transpileModule('export class H extends ViewPU {' + methods.map(n => n.getText()).join('\n') + '}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exports1, ViewPU, __Common__: common, FileGridLayout, TransitionEffect: { IDENTITY: {} },
  FileGridCell: class { constructor(_owner, params) { this.params = params; } } });
const h = new exports1.H(), entry = { path: '/photo/1' };
Object.assign(h, { pageWidthVp: 1440, pageHeightVp: 960, selectionMode: false,
  gridThumbnailComponentId: e => e.path, gridTileComponentId: e => 'tile:' + e.path,
  isImage: () => true, isVideo: () => false, FileGridThumbnail() {} });
h.FileGridInteractiveCell(entry, 1);
assert.equal(created.params.selectionMode, false); assert.equal(widths.at(-1), 1434 / 7);
assert.equal(created.params.showName, false, 'image tiles retain their existing full-square layout');
h.selectionMode = true; h.pageWidthVp = 960; h.pageHeightVp = 1440;
h.isImage = () => false;
for (const { callback } of callbacks) callback(1, false);
assert.equal(updated.selectionMode, true, 'existing cells must enter multi-select without being rebuilt');
assert.equal(updated.showName, true, 'non-image tiles show their filename after a retained entry changes type');
assert.equal(widths.at(-1), 956 / 5, 'existing cells must resize after a column change');
assert.equal(updated.tileWidth, widths.at(-1), 'file layout and the native cell use the same width');
h.isVideo = () => true;
for (const { callback } of callbacks) callback(1, false);
assert.equal(updated.showName, false, 'videos keep their original full-square cover without a file label');
entry.isDirectory = true;
for (const { callback } of callbacks) callback(1, false);
assert.equal(updated.showName, true, 'folders with media-like names still use the file layout');

console.log('Compiled retained-cell selection and viewport resize updates passed');

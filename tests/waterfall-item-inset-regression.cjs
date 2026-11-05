// Verify retained native FlowItems after prefix insertion, not a rebuilt list.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const ts = require(process.argv[2]);
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name);
  if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {} } };
  const exports = {}; cache.set(name, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/' + name + '.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true }
  }).outputText, { exports, Observed: value => value, require(key) {
    return load(key.startsWith('.') ? path.posix.normalize(path.posix.join(path.posix.dirname(name), key)) : key);
  } });
  return exports;
}
const { FileEntryDataSource } = load('model/FileEntryDataSource');
const { FileEntry } = load('model/FileEntry');
const pageSource = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = pageSource.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = pageSource.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return pageSource.slice(start, start + end + 1);
}
const generatedFile = 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts';
const generated = ts.createSourceFile(generatedFile, fs.readFileSync(generatedFile, 'utf8'), ts.ScriptTarget.Latest, true);
const page = generated.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'Index');
const build = page.members.find(n => n.name?.text === 'WaterfallFileList');
let callback;
function find(node) {
  if (ts.isArrowFunction(node) && node.body.getText(generated).includes('FlowItem.margin(') &&
    !node.body.getText(generated).includes('this.lazyForEachUpdateFunction')) callback = node;
  ts.forEachChild(node, find);
}
find(build); assert.ok(callback, 'SDK-generated FlowItem attribute update callback');
let margin;
const FlowItem = new Proxy({}, { get: (_, name) => value => { if (name === 'margin') margin = value; } });
const exportsObject = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' + method('fileItemTopInset') +
  '\n}\nexport function update(entry) { const callback = ' + callback.getText(generated) +
  '; callback(1, false); }', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, FlowItem });
const entries = Array.from({ length: 48 }, (_, i) => Object.assign(new FileEntry(), { path: '/photos/' + (48 + i) }));
const data = new FileEntryDataSource(entries.slice(12, 24));
data.bumpInPlace = true;
let columns = 5;
const h = new exportsObject.Page();
Object.assign(h, { waterfallBatchEpoch: 0, waterfallDataSource: data, waterfallColumnCount: () => columns,
  waterfallContentTopInset: () => 135, fileContentTopInset: () => 115,
  waterfallEntryIndex: e => data.indexOfPath(e.path) });
const update = entry => { margin = undefined; exportsObject.update.call(h, entry); return margin.top; };
const oldHead = data.getData(0);
assert.equal(update(oldHead), 135);
data.prepend(entries.slice(0, 12)); h.waterfallBatchEpoch++;
assert.equal(data.getData(12), oldHead, 'the same entry/native callback survives prepend');
assert.equal(update(oldHead), 0, 'the old first row must lose its header gap when its local index changes');
for (let i = 0; i < 24; i++) assert.equal(update(data.getData(i)), i < 5 ? 135 : 0,
  'header space belongs only to the new first row');
data.append(entries.slice(24)); h.waterfallBatchEpoch++;
assert.equal(update(oldHead), 0, 'append must not reintroduce an old group header');
columns = 3;
assert.equal(update(data.getData(2)), 135); assert.equal(update(data.getData(3)), 0, 'column changes update retained item margins');
data.replace(entries.slice(36)); h.waterfallBatchEpoch++;
assert.equal(update(oldHead), 0, 'a retired item cannot keep header space');
assert.equal(update(data.getData(0)), 135, 'a cold indexed jump starts with one new header');
const grid = new FileEntryDataSource(entries.slice(12, 24)); grid.bumpInPlace = true;
Object.assign(h, { entries: entries.slice(12, 24), fileEntryDataSource: grid, fileGridColumnCount: () => 4 });
const gridHead = grid.getData(0);
assert.equal(h.fileItemTopInset(gridHead, 'grid'), 115);
grid.prepend(entries.slice(0, 12)); h.entries = entries.slice(0, 24);
assert.equal(h.fileItemTopInset(gridHead, 'grid'), 0, 'grid also removes old head spacing after insertion');
for (let i = 0; i < grid.totalCount(); i++) assert.equal(h.fileItemTopInset(grid.getData(i), 'grid'), i < 4 ? 115 : 0);
grid.reconcile(h.entries.slice(2)); h.entries = h.entries.slice(2);
assert.equal(h.fileItemTopInset(grid.getData(3), 'grid'), 115, 'grid deletion updates retained first-row membership');
assert.equal(h.fileItemTopInset(grid.getData(4), 'grid'), 0);
assert.doesNotMatch(pageSource.match(/LazyForEach\(this\.waterfallDataSource,[\s\S]*?\.onAppear\(\(\) =>/)?.[0] || '',
  /top: index </, 'the flow must not capture the initial LazyForEach index for its margin');
console.log('PASS compiled waterfall item inset: same retained callback through prepend/append/column change/jump, current O(1) path index and one header row');

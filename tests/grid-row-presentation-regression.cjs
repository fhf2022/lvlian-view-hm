// node tests/grid-row-presentation-regression.cjs <SDK typescript.js>
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
function load(file, dependencies) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true }
  }).outputText, { exports, require: name => dependencies[name] || {}, Observed: target => target,
    console });
  return exports;
}
const { FileEntry } = load('entry/src/main/ets/model/FileEntry.ets', {});
const { FileEntryDataSource } = load('entry/src/main/ets/model/FileEntryDataSource.ets', {
  './FileEntry': { FileEntry }, '@kit.PerformanceAnalysisKit': { hilog: { info() {} } }
});
const { FileGridRows } = load('entry/src/main/ets/model/FileGridRows.ets', {});
const { FileGridLayout } = load('entry/src/main/ets/ui/FileGridLayout.ets', {});
function entries(n, offset = 0) {
  return Array.from({ length: n }, (_, i) => { const e = new FileEntry(); e.path = '/photo/' + (offset + i); e.name = (offset + i) + '.jpg'; return e; });
}
(async () => {
  // 50,000 files are adapted lazily; row count and tail/append remain exact.
  const source = new FileEntryDataSource(entries(50000)); source.bumpInPlace = true;
  const rows = new FileGridRows(source); rows.configure(10);
  const events = []; rows.registerDataChangeListener({ onDataReloaded() { events.push('reload'); }, onDataChange(i) { events.push(['change', i]); }, onDataAdd(i) { events.push(['add', i]); } });
  assert.equal(rows.totalCount(), 5000); assert.equal(rows.nativeIndex(49999), 4999);
  const row = rows.getData(4999); assert.equal(row.entries[9].path, '/photo/49999');
  const prefix = rows.getData(0); source.append(entries(103, 50000));
  assert.equal(rows.totalCount(), 5011); assert.equal(rows.getData(5010).entries.length, 3);
  assert.equal(rows.getData(0), prefix); assert.ok(!events.includes('reload'), 'tail pages must not reload visible rows');
  assert.equal(events.filter(e => e[0] === 'add').length, 11);
  for (let i = 0; i < rows.totalCount(); i++) rows.getData(i);
  assert.ok(rows.cache.size <= 128);
  rows.configure(6); assert.equal(rows.totalCount(), 8351); assert.equal(rows.nativeIndex(50099), 8349);
  source.insertAt(3, entries(1, 90000)[0]); assert.equal(rows.getData(0).entries[3].path, '/photo/90000');

  const indexSource = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
  const methods = ['nativeFileChildIndex', 'fileChildRect', 'fileChildIndexAt'].map(name => {
    const start = indexSource.indexOf('  private ' + name + '(');
    const tail = indexSource.slice(start + 1); const end = tail.search(/^  (?:private |@Builder)/m);
    return indexSource.slice(start, start + end + 1);
  });
  const box = { exports: {}, FileGridLayout };
  vm.runInNewContext(ts.transpileModule('export class H { ' + methods.join('\n') + '}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, box);
  const mapping = new box.exports.H(); const requests = [];
  let hitRow = 2;
  const gridScroller = { getItemIndex() { return hitRow; },
    getItemRect(index) { requests.push(index); return { x: 0, y: 220, width: 605, height: 100 }; } };
  Object.assign(mapping, { fileListScroller: gridScroller, fileViewMode: 'grid', fileGridRows: rows });
  assert.equal(mapping.nativeFileChildIndex(gridScroller, 17), 2);
  assert.equal(JSON.stringify(mapping.fileChildRect(gridScroller, 17)), JSON.stringify({ x: 505, y: 220, width: 100, height: 100 }));
  assert.equal(requests.at(-1), 2);
  assert.equal(mapping.fileChildIndexAt(gridScroller, 555, 250), 17, 'row and x position identify the file');
  assert.equal(mapping.fileChildIndexAt(gridScroller, 0, 250), 12);
  hitRow = -1; assert.equal(mapping.fileChildIndexAt(gridScroller, 555, 250), -1);
  hitRow = rows.totalCount() - 1;
  assert.equal(mapping.fileChildIndexAt(gridScroller, 604, 250), -1, 'blank tail columns cannot select another file');
  const unrelated = { getItemIndex: () => 17 };
  assert.equal(mapping.fileChildIndexAt(unrelated, 555, 250), 17, 'other native containers retain their own indexes');
  mapping.fileViewMode = 'list'; assert.equal(mapping.nativeFileChildIndex(gridScroller, 17), 17);
  hitRow = 4; assert.equal(mapping.fileChildIndexAt(gridScroller, 555, 250), 4, 'list header offset remains with the caller');

  // Page append fills the same observed tail row and keeps existing cells alive.
  const partialSource = new FileEntryDataSource(entries(13)); partialSource.bumpInPlace = true;
  const partial = new FileGridRows(partialSource); partial.configure(10);
  const changes = []; const listener = { onDataReloaded() { changes.push('reload'); },
    onDataChange(i) { changes.push(['change', i]); }, onDataAdd(i) { changes.push(['add', i]); } };
  partial.registerDataChangeListener(listener); partial.registerDataChangeListener(listener);
  const tail = partial.getData(1), firstMember = tail.entries[0];
  partialSource.append(entries(8, 13));
  assert.equal(partial.getData(1), tail);
  assert.equal(tail.entries.length, 10); assert.equal(tail.entries[0], firstMember);
  assert.equal(partial.getData(2).entries.length, 1);
  assert.equal(JSON.stringify(changes), JSON.stringify([['change', 1], ['add', 2]]));
  partialSource.notifyItemChanged(10);
  assert.equal(tail.entries[0], firstMember); assert.equal(firstMember.previewRevision, 1);
  partialSource.bumpInPlace = false; partialSource.notifyItemChanged(10);
  assert.notEqual(tail.entries[0], firstMember, 'non-in-place sources publish the new object');
  partial.unregisterDataChangeListener(listener); changes.length = 0;
  partialSource.append(entries(3, 21)); assert.equal(changes.length, 0);
  partial.configure(6); assert.equal(partial.totalCount(), 4);
  assert.equal(partial.getData(2).entries[0].path, '/photo/12');
  partialSource.replace([]); assert.equal(partial.totalCount(), 0); assert.equal(partial.cache.size, 0);

  const guardStart = indexSource.indexOf('  private fileGridRowCacheEnabled(');
  const guardEnd = indexSource.indexOf('  private fileChildRect(', guardStart);
  const guardBox = { exports: {} };
  vm.runInNewContext(ts.transpileModule('export class H {' + indexSource.slice(guardStart, guardEnd) + '}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, guardBox);
  const guard = new guardBox.exports.H();
  Object.assign(guard, { selectionMode: false, viewerBlocksFileContent: false, showImageViewer: false,
    viewerEntryTransitionActive: false, viewerClosePending: false, contextMenuEntry: null,
    isImage: e => !e.isDirectory && /\.(jpe?g|png|gif|webp)$/i.test(e.name) });
  assert.equal(guard.fileGridRowCacheEnabled({ entries: entries(10) }), true);
  for (const flag of ['selectionMode', 'viewerBlocksFileContent', 'showImageViewer', 'viewerEntryTransitionActive', 'viewerClosePending']) {
    guard[flag] = true; assert.equal(guard.fileGridRowCacheEnabled({ entries: entries(10) }), false, flag); guard[flag] = false;
  }
  guard.contextMenuEntry = {}; assert.equal(guard.fileGridRowCacheEnabled({ entries: entries(10) }), false);
  guard.contextMenuEntry = null;
  for (const name of ['animated.gif', 'animated.webp', 'movie.mp4']) {
    assert.equal(guard.fileGridRowCacheEnabled({ entries: [{ name }] }), false, name);
  }
  assert.equal(guard.fileGridRowCacheEnabled({ entries: [{ name: 'folder.jpg', isDirectory: true }] }), false);
  console.log('Grid row laziness, pagination, identity, bounded cache, index/rectangle and interaction guards passed');
})().catch(error => { console.error(error); process.exitCode = 1; });

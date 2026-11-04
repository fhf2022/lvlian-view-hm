const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const exportsForTest = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' + [
  'prepareSearchReturn', 'captureSearchSession', 'withSelectionExit', 'runCommittedViewerAction',
  'entryNameError', 'childPath'
].map(method).join('\n') + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exportsForTest });
(async () => {
  for (const mode of ['image', 'directory', 'audio', 'video']) {
    const p = new exportsForTest.Page();
    Object.assign(p, { searchSession: null, searchScrollOffset: 17, searchQuery: 'fixture', searchScope: 'current',
      searchResults: [{ path: '/temp/fixture' }], searchLoading: false, searchHistoryExpanded: false,
      createSearchSession: () => ({ originPath: '/temp' }), searchResultScroller: { currentOffset: () => ({ yOffset: 904 }) } });
    p.prepareSearchReturn(mode);
    assert.equal(p.searchSession.returnMode, mode); assert.equal(p.searchSession.scrollOffset, 904);
    assert.equal(p.searchSession.originPath, '/temp');
    p.searchResultScroller.currentOffset = () => { throw Error('unmounted'); };
    p.prepareSearchReturn(mode); assert.equal(p.searchSession.scrollOffset, 904, 'missing scroller retains the last valid offset');
  }
  const p = new exportsForTest.Page(), entry = { path: '/temp/fixture' }, sequence = [];
  Object.assign(p, { selectedSingleEntry: () => entry,
    exitSelectionMode() { sequence.push('exit'); p.selectedSingleEntry = () => null; } });
  await p.withSelectionExit(async actual => { assert.equal(actual, entry); sequence.push('action'); });
  assert.deepEqual(sequence, ['exit', 'action'], 'selection is captured before clearing and the action runs after clearing');
  await p.withSelectionExit(() => assert.fail('no single selection')); assert.equal(sequence.length, 2);
  for (const action of ['save', 'share', 'load-original', 'delete']) {
    sequence.length = 0;
    Object.assign(p, { committedViewerActionEntry: () => entry, closeImageMoreMenu() { sequence.push('close'); } });
    await p.runCommittedViewerAction(action, async actual => { assert.equal(actual, entry); sequence.push('run'); });
    assert.deepEqual(sequence, ['close', 'run'], 'a bottom-bar action cannot leave the More popup over its result');
  }
  p.committedViewerActionEntry = () => null; sequence.length = 0;
  await p.runCommittedViewerAction('save', () => assert.fail('stale viewer action'));
  assert.equal(sequence.length, 0, 'uncommitted or closing pages cannot execute an action');
  for (const invalid of ['', '.', '..', 'a/b', 'a\\b']) assert.ok(p.entryNameError(invalid, 'name'));
  assert.equal(p.entryNameError('fixture.jpg', 'name'), '');
  assert.equal(p.childPath('/', 'fixture'), '/fixture');
  assert.equal(p.childPath('/temp///', 'fixture'), '/temp/fixture');
  console.log('PASS shared page actions: live search offsets for four routes, selection capture, popup cleanup before viewer actions, stale guards and safe child paths');
})().catch(error => { console.error(error); process.exitCode = 1; });

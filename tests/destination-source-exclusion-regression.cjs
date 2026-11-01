const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const ex = {};
vm.runInNewContext(ts.transpileModule('export class Picker {\n' + [
  'beginDestinationPickerForEntries', 'destinationPathKey', 'destinationContainsSource',
  'fetchDestinationFolders', 'loadDestinationEntries', 'destinationUserRootPath', 'confirmDestinationOperation'
].map(method).join('\n') + '\n}', { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText, { exports: ex, HapticFeedback: { success() {} } });

const folder = path => ({ path, name: path.split('/').at(-1), isDirectory: true });
const file = path => ({ ...folder(path), isDirectory: false });
const parent = '/home/user';
function make(operation, selected, entries) {
  const p = new ex.Picker(), rows = [], requests = [], errors = [];
  Object.assign(p, {
    username: 'user', rootKind: 'personal', personalRoots: [folder(parent)], sharedRoots: [],
    currentPath: parent, currentRootType: 3, currentPageHasMore: false, directoryTimeline: { complete: true },
    entries, destinationSourceFolders: new Set(), destinationPickerCloseToken: 0, destinationLoadToken: 0,
    navigationRequestId: 0, destinationDataSource: { replace: items => rows.push(items) },
    repository: {
      sessionIdentity: () => 'account',
      ensureDirectoryIndex: async path => { requests.push(['read', path]); return { entries }; },
      copy: async (paths, target) => requests.push(['copy', paths, target]),
      move: async (paths, target) => requests.push(['move', paths, target])
    },
    parentPath: path => path.slice(0, path.lastIndexOf('/')),
    closeActionMenu() {}, closeDestinationPicker() {}, showImmersiveToast() {},
    refreshCurrentDirectory: async () => {},
    presentErrorMessage: (...args) => errors.push(args), reportError: error => { throw error; }
  });
  p.beginDestinationPickerForEntries(operation, selected);
  return { p, rows, requests, errors };
}
const tick = async () => { for (let i = 0; i < 10; i++) await Promise.resolve(); };
(async () => {
  const a = folder(parent + '/A'), b = folder(parent + '/B'), sibling = folder(parent + '/A-backup');
  const child = folder(a.path + '/child'), other = folder(parent + '/Other');
  const entries = [a, b, sibling, child, other, file(parent + '/note.txt')];
  for (const operation of ['copy', 'move']) {
    const h = make(operation, [a, b, file(parent + '/note.txt')], entries);
    await tick();
    assert.deepEqual(Array.from(h.rows.at(-1), x => x.path), [sibling.path, other.path]);
    assert.equal(entries.length, 6, 'picker filtering never mutates the mounted file list');
    const rowsBefore = h.rows.length;
    for (const target of [a.path, child.path, b.path + '/nested/deep']) {
      await h.p.loadDestinationEntries(target);
      assert.equal(h.p.destinationPath, parent, 'forbidden navigation retains current location');
      h.p.destinationPath = target;
      await h.p.confirmDestinationOperation();
      h.p.destinationPath = parent;
    }
    assert.equal(h.requests.length, 0, 'self/descendant targets trigger no read, copy or move request');
    assert.equal(h.rows.length, rowsBefore, 'blocked navigation does not clear the visible list');
    assert.equal(h.errors.length, 3, 'submission has the same source guard as navigation');
    await h.p.loadDestinationEntries(sibling.path);
    assert.equal(h.requests[0][1], sibling.path, 'same-prefix sibling remains navigable');
    await h.p.confirmDestinationOperation();
    assert.equal(h.requests.at(-1)[0], operation, 'legal target still reaches the existing operation');
  }
  const normalized = make('copy', [folder('/home//user/A///')], [a, sibling]);
  await tick();
  assert.deepEqual(Array.from(normalized.rows.at(-1), x => x.path), [sibling.path]);
  assert.equal(normalized.p.destinationContainsSource('/home/user/A//child/'), true);
  const upload = make('upload', [a], entries);
  await tick();
  assert.equal(upload.p.destinationContainsSource(a.path), false);
  assert.equal(upload.rows.at(-1).length, 5, 'upload destinations retain every folder');
  const filesOnly = make('copy', [file(parent + '/A')], [a, sibling]);
  await tick();
  assert.equal(filesOnly.rows.at(-1).length, 2, 'only selected directories exclude destinations');
  const many = Array.from({ length: 5000 }, (_, i) => folder(parent + '/F' + i));
  const large = make('copy', many, [...many, other]);
  await tick();
  assert.deepEqual(Array.from(large.rows.at(-1), x => x.path), [other.path]);
  console.log('PASS source exclusion: copy/move, mixed multiselect, descendants, same-prefix siblings, path separators, upload, 5000 folders');
})().catch(error => { console.error(error); process.exitCode = 1; });

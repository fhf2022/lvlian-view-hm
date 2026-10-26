const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const exported = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' +
  ['refreshCurrentDirectory', 'confirmDestinationOperation'].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exported, HapticFeedback: { success() {} } });
const tick = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
function make(root = false) {
  const page = new exported.Page(), published = [];
  let finish, identity = 'nas|account';
  const pending = new Promise(resolve => { finish = resolve; });
  Object.assign(page, {
    currentPath: root ? '' : '/home/user/Photos', currentRootType: root ? 2 : 3,
    rootKind: 'personal', currentPageIndex: 1, directoryIndexRequestToken: 0, navigationRequestId: 1,
    destinationOperation: 'copy', destinationSelectedEntries: [{ path: '/home/user/Photos/a.jpg' }],
    destinationPath: '/home/user/Other', destinationLoading: false,
    repository: { sessionIdentity: () => identity, clearDirectoryCache() {}, invalidateDirectory() {},
      getRootWithCache: () => pending, copy: async () => {} },
    loadVisibleDirectoryPages: () => pending,
    clearConfirmedDeletedPaths() {}, filterDeletedEntries: entries => entries,
    setCurrentPageState() {}, replaceEntries: entries => published.push(entries),
    updateDirectoryCount() {}, resetPreviewState() {},
    showImmersiveToast: () => { page.toast = true; },
    closeDestinationPicker: () => { page.closed = true; }, reportError: () => { page.failed = true; }
  });
  return { page, published, finish: () => finish(root ? { personal: [], shared: [] } :
    { entries: [{ path: '/home/user/Photos/a.jpg' }], pageIndex: 1, hasMore: false, totalCount: 1 }),
    changeIdentity: () => { identity = 'nas|another-account'; } };
}
(async () => {
  for (const root of [false, true]) {
    const state = make(root), job = state.page.refreshCurrentDirectory();
    state.page.navigationRequestId++;
    state.finish(); await job;
    assert.equal(state.published.length, 0, 'late root/directory refresh cannot overwrite a new scene');
  }
  let state = make(), job = state.page.refreshCurrentDirectory();
  state.changeIdentity(); state.finish(); await job;
  assert.equal(state.published.length, 0, 'old-account refresh cannot publish');

  state = make(); job = state.page.confirmDestinationOperation();
  await tick(); state.finish(); await job;
  assert.equal(state.published.length, 1);
  assert.equal(state.page.closed, true, 'the refresh increment must not suppress normal copy completion');
  assert.equal(state.page.toast, true);

  state = make(); job = state.page.confirmDestinationOperation();
  await tick(); state.page.navigationRequestId++; state.page.currentPath = '/home/user/Incoming';
  state.finish(); await job;
  assert.equal(state.published.length, 0);
  assert.equal(state.page.closed, undefined, 'old completion cannot close the replacement picker');
  assert.equal(state.page.toast, undefined);
  assert.equal(state.page.destinationOperationRunning, false);
  console.log('PASS mutation refresh: root/directory and account isolation, late continuation replacement, normal copy completion');
})().catch(error => { console.error(error); process.exitCode = 1; });

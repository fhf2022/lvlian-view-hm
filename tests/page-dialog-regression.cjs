const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const next = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + next + 1);
}
const exported = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' +
  ['presentPageDialog', 'closePageDialogs', 'showTrackedDialog', 'actionMenuButtons'].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exported, DialogAlignment: { Center: 0 }, Glass: { windowInset: 16 } });
const tick = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
function make() {
  const page = new exported.Page(), dialogs = [], closed = [];
  Object.assign(page, { pageDialogClosers: new Set(), continuationContextToken: 0,
    continuationDialogCount: 0, effectivePageWidth: () => 1200,
    getUIContext: () => ({ getPromptAction: () => ({
      openCustomDialog: options => new Promise((resolve, reject) => {
        dialogs.push({ options, resolve, reject }); options.builder();
      }),
      closeCustomDialog: id => { closed.push(id); dialogs[id].options.onDidDisappear(); }
    }) }) });
  return { page, dialogs, closed };
}
(async () => {
  let state = make(), select;
  let result = state.page.presentPageDialog(finish => { select = finish; }, {});
  state.page.closePageDialogs();
  assert.equal(state.closed.length, 0, 'close before native ID is available is deferred');
  state.dialogs[0].resolve(0); await tick();
  assert.equal((await result).index, -1);
  assert.equal(state.page.pageDialogClosers.size, 0);
  assert.deepEqual(state.closed, [0]);

  state = make();
  result = state.page.presentPageDialog(finish => { select = finish; }, {});
  state.dialogs[0].resolve(0); await tick(); select(1); select(0);
  assert.equal((await result).index, 1, 'confirmation retains the original button index');
  assert.deepEqual(state.closed, [0], 'repeated taps close once');

  state = make();
  result = state.page.presentPageDialog(() => {}, {});
  state.dialogs[0].resolve(0); await tick(); state.dialogs[0].options.onDidDisappear();
  assert.equal((await result).index, -1, 'system Back/outside dismissal cancels');
  assert.equal(state.page.pageDialogClosers.size, 0);

  state = make();
  result = state.page.presentPageDialog(() => {}, {});
  state.dialogs[0].reject(new Error('native open failed'));
  await assert.rejects(result, /native open failed/);
  assert.equal(state.page.pageDialogClosers.size, 0);

  state = make();
  state.page.presentConfirmationDialog = () => state.page.presentPageDialog(finish => { select = finish; }, {});
  result = state.page.showTrackedDialog({ title: 'delete' });
  state.dialogs[0].resolve(0); await tick();
  state.page.continuationContextToken++; state.page.closePageDialogs();
  assert.equal((await result).index, -1, 'continuation cancels pending confirmation');
  assert.equal(state.page.continuationDialogCount, 0);
  const selections = [];
  const buttons = state.page.actionMenuButtons({ buttons: [
    { text: '明细', color: '#fff' }, { text: '继续', color: '#fff' },
    { text: '移除', color: '#D34D5C' }, { text: '取消', color: '#fff' }
  ] }, index => selections.push(index));
  assert.equal(buttons.length, 4, 'all album task actions must remain visible');
  buttons.forEach(button => button.action());
  assert.deepEqual(selections, [0, 1, 2, 3], 'native action list keeps original command indexes');
  assert.equal(buttons[2].fontColor, '#D34D5C');
  assert.doesNotMatch(source, /getPromptAction\(\)\.showActionMenu\(/,
    'no remaining unclosable native action menu can cover an incoming continuation');
  assert.match(source, /SystemAlertDialog\(/, 'official confirmation component');
  console.log('PASS shared dialogs: late native IDs, confirmation index, Back/outside, open failure and continuation cancellation');
})().catch(error => { console.error(error); process.exitCode = 1; });

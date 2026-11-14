const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const KeyCode = {
  KEYCODE_BUTTON_A: 2301, KEYCODE_BUTTON_B: 2302,
  KEYCODE_DPAD_UP: 2012, KEYCODE_DPAD_DOWN: 2013,
  KEYCODE_DPAD_LEFT: 2014, KEYCODE_DPAD_RIGHT: 2015,
};
let now = 1000;
function load(name, dependencies = {}) {
  const source = fs.readFileSync(`entry/src/main/ets/ui/${name}.ets`, 'utf8');
  const exports = {};
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
  });
  vm.runInNewContext(outputText, {
    exports, require: id => dependencies[id], Date: { now: () => now },
  });
  return exports;
}

const navigation = load('GamepadNavigation');
const { GamepadModalFocus } = load('GamepadModalFocus', {
  '@kit.InputKit': { KeyCode }, './GamepadNavigation': navigation,
});
const { KEYCODE_BUTTON_A: a, KEYCODE_BUTTON_B: b, KEYCODE_DPAD_DOWN: down } = KeyCode;
const activated = [];
const drawn = [];
let visible = ['delete', 'cancel', 'details'];
let backs = 0;
const modal = new GamepadModalFocus(
  'dialog', () => visible.map(id => ({ id, activate: () => activated.push(id) })),
  id => drawn.push(id), () => { backs++; }, () => 'cancel',
);
const tap = key => { modal.key(key, true); modal.key(key, false); };

modal.focusInitial();
assert.equal(drawn.at(-1), 'cancel', 'confirmation initially focuses the safe action');
modal.key(a, false);
assert.deepEqual(activated, [], 'releasing the A press that opened a modal cannot confirm it');
tap(a);
assert.deepEqual(activated, ['cancel']);

modal.key(a, true);
tap(down);
modal.key(a, true);
modal.key(a, false);
assert.equal(drawn.at(-1), 'details');
assert.deepEqual(activated, ['cancel'], 'moving focus cancels the held A press, including key repeats');
modal.key(a, true);
visible = ['delete', 'cancel'];
modal.key(a, false);
assert.deepEqual(activated, ['cancel'], 'a disappearing target cannot be activated on release');

modal.key(b, false);
assert.equal(backs, 0);
tap(b);
assert.equal(backs, 1);
modal.key(b, true);
modal.reset();
modal.key(b, false);
assert.equal(backs, 1, 'closing a scope clears its outstanding press');

visible = ['cancel', 'one', 'two', 'three', 'four'];
modal.focusInitial();
tap(down);
modal.axis(0, 1, true);
assert.equal(drawn.at(-1), 'one', 'a hat event and digital event must advance once');
modal.axis(0, 0, true);
modal.axis(0, 1, false);
assert.equal(drawn.at(-1), 'two');
now += 429;
modal.tick();
assert.equal(drawn.at(-1), 'two');
now++;
modal.tick();
assert.equal(drawn.at(-1), 'three');
now += 100;
modal.tick();
assert.equal(drawn.at(-1), 'four');
modal.axis(0, 0, false);
now += 1000;
modal.tick();
assert.equal(drawn.at(-1), 'four');
assert.ok(navigation.GamepadNavigation.repeatInterval(0.75, false) >
  navigation.GamepadNavigation.repeatInterval(1, false));

const press = new navigation.GamepadPressFilter();
assert.equal(press.accept(a, true, 0), true, 'initial A down reaches the file list');
assert.equal(press.accept(a, true, 390), false, 'the A hold that opened a menu cannot confirm it');
assert.equal(press.accept(a, false, 500), true);
assert.equal(press.accept(a, true, 580), true, 'a fresh press reaches the menu');
assert.equal(press.accept(a, false, 600), true);
assert.equal(press.accept(a, true, 607), false, 'a queued copy cannot confirm the next surface');
assert.equal(press.accept(a, false, 608), true);
assert.equal(press.accept(a, true, 680), true, 'the next physical tap can still confirm');
assert.equal(press.accept(a, true, 1400), false, 'holding A cannot activate the next surface after a timeout');
press.accept(a, false, 1450);
assert.equal(press.accept(a, true, 1510), true, 'release then press activates the next surface');

modal.reset();
modal.focusInitial();
tap(down);
modal.suspend();
assert.equal(drawn.at(-1), '');
modal.focusInitial();
assert.equal(drawn.at(-1), 'one', 'returning from a child dialog restores the originating item');

let systemBack = 0;
const systemContent = new GamepadModalFocus('system-picker', () => [], () => {}, () => systemBack++, () => '', () => false, true);
assert.equal(systemContent.key(a, true), false, 'A reaches the system content instead of the wrapper close action');
assert.equal(systemContent.key(down, true), false, 'native content retains directional key ownership');
systemContent.key(b, true); systemContent.key(b, false);
assert.equal(systemBack, 1, 'B still closes the app-owned picker wrapper');

const history = new navigation.GamepadFocusHistory();
history.remember('account-a:parent', 'folder-b', 8);
history.remember('account-a:child', 'file-c', 3);
assert.equal(history.get('account-a:parent').id, 'folder-b');
assert.equal(history.get('account-b:parent'), undefined, 'accounts do not share focus history');

// Exercise the production dispatcher against the same callbacks registered by touch.
const pageSource = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const route = pageSource.slice(pageSource.indexOf('  private routeGamepadKey('),
  pageSource.indexOf('  private handleGamepadButton('));
const pageExports = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' + route + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: pageExports, KeyCode, KeyType: { Down: 0, Up: 1 }, KeySource: { JOYSTICK: 1 },
  GamepadModalFocus, DEBUG: false });
const page = new pageExports.Page();
let actions = 0;
let menu = 'selmore';
let foreground = true;
Object.assign(page, {
  gamepadPresses: new navigation.GamepadPressFilter(),
  getMonotonicNow: () => now,
  currentGamepadModal: () => null,
  openGamepadMenu: () => menu,
  gamepadAvailable: () => foreground,
  focusGamepadMenu: () => {},
  gamepadItem: '移动',
  slideItems: new Map([['selmore:移动', { action: () => { actions++; menu = ''; } }]]),
  gamepadBack: () => { menu = ''; },
  ordinaryGamepadScope: () => '',
  handleGamepadButton: () => true,
});
page.routeGamepadKey(a, 0, 6, 1, 'arkui');
assert.equal(actions, 1, 'A invokes the actual registered touch action on press');
page.routeGamepadKey(a, 0, 6, 1, 'native');
assert.equal(actions, 1, 'the second input channel cannot invoke the action again');
page.routeGamepadKey(a, 1, 6, 1, 'arkui');
now += 100;
menu = 'selmore';
foreground = false;
page.routeGamepadKey(a, 0, 6, 1, 'arkui');
assert.equal(actions, 1, 'background input cannot execute a menu action');

const fileFocus = pageSource.slice(pageSource.indexOf('  private gamepadDirectoryKey('),
  pageSource.indexOf('  private gamepadMoveFile(')) +
  pageSource.slice(pageSource.indexOf('  private gamepadMarkInput('), pageSource.indexOf('  private gamepadFocused('));
vm.runInNewContext(ts.transpileModule('export class FilePage {\n' + fileFocus + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: pageExports });
const files = new pageExports.FilePage();
let rows = [{ path: 'a' }, { path: 'b' }, { path: 'c' }];
let reveals = 0;
Object.assign(files, {
  repository: { cacheScopeHash: () => 'account-a' },
  currentRootType: 3, currentPath: 'parent', gamepadFileDirectory: '',
  gamepadFilePath: '', fileVisibleStartIndex: 2, fileViewMode: 'list',
  gamepadFocusHistory: new navigation.GamepadFocusHistory(),
  fileEntryDataSource: {
    totalCount: () => rows.length,
    indexOfPath: path => rows.findIndex(row => row.path === path),
    getData: index => rows[index],
  },
  scrollToGamepadFile: () => { reveals++; },
});
assert.equal(files.gamepadCurrentFile().path, 'b');
files.currentPath = 'child';
rows = [{ path: 'child-item' }];
files.gamepadCurrentFile();
files.currentPath = 'parent';
rows = [{ path: 'c' }, { path: 'a' }, { path: 'b' }];
assert.equal(files.gamepadCurrentFile().path, 'b', 'return restores the entrance after reordering');
assert.equal(files.gamepadFileIndex, 2);
assert.equal(reveals, 1, 'return reveals the restored item');
rows = [{ path: 'c' }, { path: 'a' }];
assert.equal(files.gamepadCurrentFile().path, 'a', 'deletion restores the nearest surviving index');

rows = [{ path: 'folder' }, { path: 'a' }, { path: 'document' }, { path: 'b' }, { path: 'c' }];
files.waterfallEntries = [rows[1], rows[3], rows[4]];
files.fileViewMode = 'waterfall'; files.waterfallVisibleStartIndex = 1;
files.gamepadFilePath = 'b';
assert.equal(files.gamepadCurrentFile().path, 'b');
assert.equal(files.gamepadFileIndex, 1);
files.fileViewMode = 'list';
assert.equal(files.gamepadCurrentFile().path, 'b');
assert.equal(files.gamepadFileIndex, 3, 'filtered waterfall indexes do not become full-directory indexes');
files.gamepadFilePath = 'c'; files.gamepadCurrentFile();
files.fileViewMode = 'grid'; files.gamepadArea = '';
Object.assign(files, { openGamepadMenu: () => '', requestGamepadInputFocus() {}, postRenderFrame() {} });
files.gamepadMarkInput();
assert.equal(files.gamepadFilePath, 'c', 'reentering content after a mode cycle keeps the latest file identity');
assert.equal(files.gamepadFileIndex, 4);
files.gamepadFilePath = '';
assert.equal(files.gamepadCurrentFile().path, 'c', 'history also resolves by identity when the live path is absent');
files.fileViewMode = 'waterfall'; files.waterfallEntries = [];
assert.equal(files.gamepadCurrentFile(), null);
assert.equal(files.gamepadFilePath, 'c', 'temporary empty metadata must not erase the cross-mode target');
files.waterfallEntries = [rows[1], rows[3], rows[4]];
files.gamepadTouchScrollPending = true; files.gamepadArea = '';
files.gamepadTouchScrollDirectory = files.gamepadDirectoryKey();
files.gamepadFilesAvailable = () => true;
files.captureFileViewAnchor = () => ({ path: 'b', y: 0 });
files.gamepadFollowTouchViewport();
files.fileViewMode = 'grid'; files.gamepadMarkInput();
assert.equal(files.gamepadFilePath, 'b', 'touch scrolling in another mode replaces the old gamepad target');
assert.equal(files.gamepadFileIndex, 3);
files.gamepadTouchScrollPending = true;
files.captureFileViewAnchor = () => ({ path: 'a', y: 0 });
files.gamepadFollowTouchViewport();
assert.equal(files.gamepadFilePath, 'b', 'late touch inertia cannot overwrite a resumed controller selection');
files.currentPath = 'unvisited'; files.fileViewMode = 'waterfall';
files.waterfallVisibleStartIndex = 2; files.fileVisibleStartIndex = 0;
assert.equal(files.gamepadCurrentFile().path, 'c', 'first waterfall focus uses its own visible range');
console.log('PASS file focus: cross-mode identity, content reentry, touch scroll, transient empty data and waterfall viewport');

const listReveal = pageSource.slice(pageSource.indexOf('  private async revealGamepadListRow('),
  pageSource.indexOf('  private gamepadBarItems('));
vm.runInNewContext(ts.transpileModule('export class ListPage {\n' + listReveal + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: pageExports, HeaderStyle: { overlayHeight: 94 },
  Glass: { barEffectTop: 20 }, ScrollAlign: { CENTER: 2 } });

async function checkListReveal() {
  const list = new pageExports.ListPage();
  const scrolls = [];
  let rect = { y: 60, height: 61 };
  Object.assign(list, {
    gamepadFilePath: 'b', gamepadArea: 'files', fileViewMode: 'list', gamepadListRevealToken: 0,
    gamepadDirectoryKey: () => 'parent', gamepadFilesAvailable: () => true, nextRenderFrame: async () => {},
    mainContentOriginY: 0, fileScrollViewport: { y: 40, height: 760 }, topSafeInset: () => 40,
    floatingBarContentInset: extra => 72 + extra,
    fileEntryDataSource: { indexOfPath: () => 16 },
    fileListScroller: {
      getItemRect: index => { assert.equal(index, 17, 'leading spacer counts as a ListItem'); return rect; },
      scrollBy: (x, y) => { scrolls.push(['delta', x, y]); rect.y -= y; },
      scrollToIndex: index => { scrolls.push(['mount', index]); rect = { y: 700, height: 61 }; },
    },
  });
  await list.revealGamepadListRow();
  assert.deepEqual(scrolls.splice(0), [['delta', 0, -34]], 'row clears the full 94vp top blur');
  await list.revealGamepadListRow();
  assert.deepEqual(scrolls, [], 'a fully visible row leaves the list still');
  rect = { y: 700, height: 61 };
  await list.revealGamepadListRow();
  assert.deepEqual(scrolls.splice(0), [['delta', 0, 93]], 'the bottom band includes the glass effect');
  rect = { y: 0, height: 0 };
  await list.revealGamepadListRow();
  assert.deepEqual(scrolls.splice(0), [['mount', 17], ['delta', 0, 93]], 'a lazy row is measured again after mounting');
  rect = { y: 60, height: 61 };
  const oldReveal = list.revealGamepadListRow();
  list.gamepadFilePath = 'c';
  await Promise.all([oldReveal, list.revealGamepadListRow()]);
  assert.deepEqual(scrolls.splice(0), [['delta', 0, -34]], 'a rapid focus move cancels the previous correction');
  rect = { y: 0, height: 0 };
  list.nextRenderFrame = async () => { list.gamepadArea = ''; };
  await list.revealGamepadListRow();
  assert.deepEqual(scrolls, [], 'a pending correction cannot override touch takeover');
  console.log('PASS list controller focus: full blur and bar clearance, minimal movement, lazy rows and input handoff');
}
checkListReveal().catch(error => { console.error(error); process.exitCode = 1; });
console.log('PASS modal focus, safe confirmation, input handoff, duplicate presses and analog repeat');

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const methods = [
  ['handleKeyboardShortcut', 'routeGamepadKey'],
  ['gamepadDpadKey', 'stopNativeMenuPad'],
  ['stepViewerImage', 'gamepadBack'],
].map(([name, end]) => {
  const start = source.indexOf(`  private ${name}(`);
  const stop = source.indexOf(`  private ${end}(`, start);
  assert.ok(start >= 0 && stop > start, `Expected method ${name}`);
  return source.slice(start, stop);
});
const KeyCode = {
  KEYCODE_ESCAPE: 2070, KEYCODE_DPAD_UP: 2012, KEYCODE_DPAD_DOWN: 2013,
  KEYCODE_DPAD_LEFT: 2014, KEYCODE_DPAD_RIGHT: 2015,
};
const KeyType = { Down: 0, Up: 1 };
const KeySource = { Keyboard: 1, JOYSTICK: 2 };
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(`export class Page {\n${methods.join('\n')}\n}`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: exportsObject, KeyCode, KeyType, KeySource });

const page = new exportsObject.Page();
const effects = [];
let now = 1000;
Object.assign(page, {
  screen: 'files', startupAuthorized: true, gamepadSourceId: -1, keyboardEscapeAction: null,
  gamepadDeviceIds: new Set([42]), gamepadArea: '', pageDialogClosers: new Set(), continuationDialogCount: 0,
  currentGamepadModal: () => null, openGamepadMenu: () => '', parentOverlayOwnsInteraction: () => false,
  activeListSurface: () => 'list', viewerGestureBlocked: () => false, getMonotonicNow: () => now,
  onBackPress: () => effects.push('back'), releaseGamepad: () => { page.gamepadArea = ''; effects.push('release'); },
  fileListScroller: { scrollBy: (_x, y) => effects.push(['files', y]) },
  waterfallScroller: { scrollBy: (_x, y) => effects.push(['waterfall', y]) },
  searchResultScroller: { scrollBy: (_x, y) => effects.push(['search', y]) },
  viewerImageIndex: 1, viewerImages: [{}, {}, {}], viewerStepUntil: 0,
  viewerSwiperController: { changeIndex: (index, animate) => effects.push(['image', index, animate]) },
});

const key = (keyCode, type = KeyType.Down, extra = {}) => page.handleKeyboardShortcut({
  keyCode, type, keySource: KeySource.Keyboard, deviceId: -1, ...extra,
});
const { KEYCODE_ESCAPE: esc, KEYCODE_DPAD_DOWN: down, KEYCODE_DPAD_UP: up,
  KEYCODE_DPAD_LEFT: left, KEYCODE_DPAD_RIGHT: right } = KeyCode;

assert.equal(key(down), true, 'an unspecified device ID does not identify a gamepad');
key(down); // Keyboard repeat scrolls again.
key(down, KeyType.Up);
assert.deepEqual(effects.splice(0), [['files', 96], ['files', 96]]);
assert.equal(page.gamepadArea, '');
assert.equal(key(down, KeyType.Down, { deviceId: 42 }), false, 'the controller still owns its arrows');
assert.equal(key(down, KeyType.Down, { keySource: KeySource.JOYSTICK }), false);
assert.equal(key(left), false, 'left is unassigned on the file surface');
page.activeListSurface = () => 'waterfall';
key(up);
page.showSearch = true;
key(down);
page.searchEditing = true;
assert.equal(key(up), false, 'input editing retains native keyboard behavior');
assert.deepEqual(effects.splice(0), [['waterfall', -96], ['search', 96]]);
page.showSearch = false;
page.searchEditing = false;

page.showImageViewer = true;
page.gamepadArea = 'canvas';
key(right);
key(right); // Do not issue another page change during the first animation.
assert.deepEqual(effects.splice(0), ['release', ['image', 2, true]]);
now += 250;
key(left);
assert.deepEqual(effects.splice(0), [['image', 0, true]]);
page.openGamepadMenu = () => 'viewermenu';
assert.equal(key(right), false, 'an open menu owns the viewer input');
key(esc); key(esc); key(esc, KeyType.Up);
assert.deepEqual(effects.splice(0), ['back'], 'holding Escape only dismisses one surface');
const dialog = { dismiss: () => effects.push('dismiss') };
page.currentGamepadModal = () => dialog;
key(esc);
key(esc, KeyType.Up);
assert.deepEqual(effects.splice(0), ['dismiss'], 'Escape uses the modal dismiss callback');
page.currentGamepadModal = () => null;
key(esc);
page.openGamepadMenu = () => '';
key(esc, KeyType.Up);
assert.deepEqual(effects, [], 'release after native menu dismissal leaves the viewer open');
key(esc, KeyType.Up);
assert.deepEqual(effects, [], 'a release where the native menu owned key-down cannot navigate back');

console.log('PASS keyboard shortcuts: keyboard/controller separation, scroll repeat, viewer paging, edit and modal routing');

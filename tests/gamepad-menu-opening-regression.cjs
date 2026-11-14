const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8').replace(/\r\n/g, '\n');
const item = source.slice(source.indexOf('class SlideActionItem {'), source.indexOf('class RowHitArea {'));
function method(start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, 'method extraction: ' + start);
  return source.slice(from, to);
}
const menu = [
  method('  private clearSlideItems(', '  private hitSlideItem('),
  method('  private gamepadMoveMenu(', '  private gamepadDirection('),
  method('  private imageViewerMoreActions(', '  @Builder\n  ImageViewerMoreContent('),
  method('  private openImageMoreMenu(', '  private closeImageMoreMenu('),
].join('\n');
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(item + '\nexport class Menu {\n' + menu + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: exportsObject, $r: id => id });
const page = new exportsObject.Menu();
page.slideItems = new Map(); page.gamepadArea = 'viewermenu'; page.gamepadItem = '旋转';
const calls = [];
for (const key of ['旋转', '其他应用打开', '重命名', '详情']) {
  page.registerSlideAction('viewermenu', key, () => calls.push(key));
}
page.gamepadMoveMenu('down');
assert.equal(page.gamepadItem, '其他应用打开', 'navigation works before any area callback');
page.gamepadMoveMenu('down'); page.gamepadMoveMenu('down'); page.gamepadMoveMenu('down');
assert.equal(page.gamepadItem, '详情', 'list navigation stops at the final action');
page.slideItems.get('viewermenu:' + page.gamepadItem).action();
assert.deepEqual(calls, ['详情'], 'A can use the same registered callback before animation geometry settles');
page.gamepadMoveMenu('left');
assert.equal(page.gamepadItem, '详情', 'horizontal input does not jump between vertical list actions');
// Native scale may report transient overlapping/zero-size rows. Order must be independent.
page.registerSlideItem('viewermenu', '重命名', { globalPosition: { x: 0, y: 0 }, width: 0, height: 0 }, () => calls.push('renamed callback'));
page.gamepadMoveMenu('up');
assert.equal(page.gamepadItem, '重命名');
page.slideItems.get('viewermenu:' + page.gamepadItem).action();
assert.equal(calls.at(-1), 'renamed callback');
page.clearSlideItems('viewermenu');
assert.equal(page.slideItems.size, 0, 'closing drops all old actions');
page.registerSlideAction('viewermenu', '旋转', () => calls.push('new view'));
page.gamepadItem = '详情'; page.gamepadMoveMenu('down');
assert.equal(page.gamepadItem, '旋转', 'reopened or changed menus choose a surviving action');

page.showImageViewer = true; page.continuationDialogCount = 0;
page.committedViewerActionEntry = () => ({ path: 'photo.jpg' });
page.isSearchViewer = () => false; page.stopGamepadAxes = () => {};
page.openImageDetails = () => calls.push('early details');
page.openImageMoreMenu(true);
page.gamepadMoveMenu('down'); page.gamepadMoveMenu('down'); page.gamepadMoveMenu('down');
page.slideItems.get('viewermenu:' + page.gamepadItem).action();
assert.equal(calls.at(-1), 'early details', 'opening prepares the same actions before any row mounts');

const styleExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/GamepadMenuStyle.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: styleExports, Color: { Transparent: 'transparent' }, $r: id => id });
const style = styleExports.GamepadMenuStyle;
assert.equal(style.ink(false, 'original'), 'original');
assert.equal(style.ink(true, 'warning', true), 'warning', 'danger actions retain warning semantics');
assert.equal(style.background(false, true), 'transparent', 'touch-only idle rows keep the original background');
assert.notEqual(style.background(true, true), style.background(true, false), 'light/dark surfaces use a quiet theme-specific tint');
const surface = fs.readFileSync('entry/src/main/ets/components/GlassMenuSurface.ets', 'utf8');
const row = fs.readFileSync('entry/src/main/ets/components/GlassMenuRow.ets', 'utf8');
const relay = fs.readFileSync('entry/src/main/ets/components/GamepadMenuKeyRelay.ets', 'utf8');
assert.ok(surface.includes('GamepadMenuKeyRelay({'), 'floating and context menus share early native key routing');
assert.ok(surface.includes('.position({ x: 0, y: 0 })'), 'relay has no contribution to menu layout');
assert.ok(!surface.includes('.defaultFocus('), 'the painted surface is not the default focus target');
assert.ok(!surface.includes('.systemMaterial('), 'popup remains the sole owner of the glass surface');
assert.ok(relay.includes('.id(this.inputId)'), 'each menu surface has its own native input target');
assert.ok(row.includes('.stateEffect(true).focusOnTouch(false)'), 'touch press animation remains but does not steal native focus');
assert.ok(!row.includes('.outline('), 'controller row selection has no rectangular outline');

// A pre-dispatch BLOCK on key-down suppressed the matching key-up on the tablet.
// Exercise the actual shared monitor and press filter with duplicate delivery:
// the monitor must observe without interrupting ArkUI's down/up lifecycle.
const monitorExports = {};
const monitorSource = relay.slice(relay.indexOf('export class GamepadMenuKeyInput'), relay.indexOf('/** Shared input receiver'));
vm.runInNewContext(ts.transpileModule(monitorSource, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, {
  exports: monitorExports,
  InputEventSubTypeMask: { KEY_DOWN: 2048, KEY_UP: 4096 },
  InputEventInterceptAction: { CONTINUE: 0, BLOCK: 1 },
});
const navigationExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/GamepadNavigation.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: navigationExports });
const filter = new navigationExports.GamepadPressFilter();
let listener, removed = 0, presses = 0, now = 1000;
const token = {};
const context = {
  addLocalInputEventMonitor(mask, callback) { assert.equal(mask, 6144); listener = callback; return token; },
  removeLocalInputEventMonitor(value) { assert.equal(value, token); removed++; },
};
const route = event => {
  const accepted = filter.accept(event.code, event.down, now);
  if (accepted && event.down) presses++;
  return true;
};
const monitor = new monitorExports.GamepadMenuKeyInput();
monitor.attach(context, route);
for (let tap = 0; tap < 2; tap++) {
  for (const down of [true, false]) {
    const event = { code: 2301, down };
    assert.equal(listener({ asKeyEvent: () => event }).action, 0, 'monitor leaves the paired release deliverable');
    route(event); // the focused component sees the same event after the monitor
    now += 100;
  }
}
assert.equal(presses, 2, 'successive taps work and duplicate down delivery does not activate twice');
monitor.detach(); monitor.detach();
assert.equal(removed, 1, 'monitor lifecycle removes only its own registration once');
console.log('PASS menu opening: pre-layout actions, stable order, paired key lifecycle, duplicate suppression and subtle selection style');

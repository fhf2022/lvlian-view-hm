const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
let timerId = 0;
const timers = new Map();
const exportsObject = {};
class AttributeUpdater {}
const kit = { AttributeUpdater, ColorMetrics: { resourceColor: value => value }, LengthMetrics: { vp: value => value } };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/GamepadControls.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, {
  exports: exportsObject, require: name => name === '@kit.ArkUI' ? kit : {}, Color: { Transparent: 0 },
  setTimeout: fn => { timers.set(++timerId, fn); return timerId; }, clearTimeout: id => timers.delete(id),
});
const { GamepadAction, GamepadControls: controls } = exportsObject;
const focusRequests = [];
const context = { runScopedTask: fn => fn(), getFocusController: () => ({ requestFocus: id => {
  focusRequests.push(id);
  if (id === 'title-action') throw new Error('150002');
} }) };
const actions = [];
function mount(scope, key, x, y, options = {}, enabled = () => true, bindClick = true, action = () => actions.push(key)) {
  const events = {};
  const writes = [];
  const node = new Proxy({}, { get: (_, prop) => (...args) => {
    if (prop.startsWith('on')) events[prop] = args[0];
    else writes.push([prop, ...args]);
    return node;
  } });
  const modifier = new GamepadAction(context, scope, key, action, enabled, key, bindClick, options);
  modifier.attribute = node;
  modifier.initializeModifier(node);
  events.onAppear?.();
  events.onAreaChange?.({}, { globalPosition: { x, y }, width: 10, height: 10 });
  return { events, writes, modifier };
}
const a = mount('parent', 'a', 0, 0);
const b = mount('parent', 'b', 0, 100);
mount('parent', 'disabled', 0, 50, {}, () => false);
controls.focus('parent');
controls.move('parent', 'down');
assert.ok(controls.isSelected('parent', 'b'), 'disabled intermediate controls are skipped');
b.events.onClick();
controls.confirm('parent', true); controls.confirm('parent', false);
assert.deepEqual(actions, ['b', 'b'], 'touch and A call the same registered action');
mount('child', 'child', 0, 0);
controls.focus('child');
assert.ok(!controls.isSelected('parent', 'b'), 'covered parent has no highlight');
controls.focus('parent');
assert.ok(controls.isSelected('parent', 'b'), 'return restores the entrance');
controls.confirm('parent', true);
controls.focus('child');
controls.confirm('child', false);
assert.deepEqual(actions, ['b', 'b'], 'release cannot activate a different surface');
controls.focus('parent');
controls.confirm('parent', true);
controls.move('parent', 'up');
controls.confirm('parent', false);
assert.equal(actions.length, 2, 'moving cancels the pending click');
let enabled = true;
mount('conditional', 'conditional', 0, 0, {}, () => enabled);
controls.focus('conditional'); controls.confirm('conditional', true);
enabled = false; controls.confirm('conditional', false);
assert.equal(actions.length, 2, 'becoming disabled during A cannot activate');
const long = mount('long', 'long', 0, 0, { hold: () => actions.push('hold') });
controls.focus('long'); controls.confirm('long', true);
for (const [id, fn] of [...timers]) { timers.delete(id); fn(); }
controls.confirm('long', false);
assert.equal(actions.at(-1), 'hold');
assert.equal(actions.filter(x => x === 'long').length, 0, 'long press does not also click');
controls.confirm('long', true); long.events.onDisAppear();
assert.equal(timers.size, 0, 'unmount cancels a pending hold');
const old = mount('refresh', 'refresh', 0, 0);
const replacement = mount('refresh', 'refresh', 0, 0, {}, () => true, true, () => actions.push('new'));
old.events.onDisAppear();
controls.focus('refresh'); controls.activate('refresh');
assert.equal(actions.at(-1), 'new', 'stale lifecycle callbacks cannot remove replacement actions');
const materialPaint = [];
const material = mount('material', 'title-action', 0, 0, { highlight: selected => materialPaint.push(selected) });
controls.focus('material'); controls.activate('material');
assert.equal(actions.at(-1), 'title-action', 'native focus refusal does not disable app-owned actions');
assert.equal(materialPaint.at(-1), true);
assert.equal(material.writes.some(([name]) => ['shadow', 'backgroundColor', 'systemMaterial', 'overlay'].includes(name)), false,
  'material callbacks add no container paint or material changes');
const input = mount('input', 'input', 0, 0, { nativeFocus: false }, () => true, false,
  () => context.getFocusController().requestFocus('input'));
const beforeInputFocus = focusRequests.length;
controls.focus('input');
assert.equal(focusRequests.length, beforeInputFocus, 'passing over an input does not open the keyboard');
assert.equal(input.events.onClick, undefined, 'native touch input remains bound to the system');
controls.confirm('input', true); controls.confirm('input', false);
assert.equal(focusRequests.at(-1), 'input', 'A explicitly begins input editing');
const adjustments = [];
mount('range', 'range', 0, 0, { adjust: direction => {
  if (!['left', 'right'].includes(direction)) return false;
  adjustments.push(direction); return true;
} }, () => true, false);
mount('range', 'below', 0, 100);
controls.focus('range'); controls.move('range', 'right'); controls.move('range', 'down');
assert.deepEqual(adjustments, ['right']);
assert.ok(controls.isSelected('range', 'below'), 'up/down exits an adjustable control');
const legacy = mount('', 'legacy', 0, 0);
assert.deepEqual(legacy.writes, [], 'manual file/viewer controls keep all existing attributes');
legacy.events.onClick();
assert.equal(actions.at(-1), 'legacy');

const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function builder(name) {
  const start = source.indexOf(`  ${name}(`);
  const end = source.indexOf('  @Builder', start + 3);
  return source.slice(start, end);
}
for (const name of ['OfficialBackButton', 'MainHeaderLeadingControl', 'SearchScopeButton', 'SearchHistoryChip', 'RecycleScopeToggle']) {
  const body = builder(name);
  assert.ok(body.includes('highlight:'), `${name}: material node must use its own ink treatment`);
  assert.ok(!body.includes('.shadow('), `${name}: material shadow is not overridden`);
}
for (const name of ['FilePageNativeHeader', 'ImageViewerNativeHeader', 'VideoPlayerNativeHeader']) {
  const body = builder(name);
  if (body) assert.ok(!body.includes('new GamepadAction'), `${name}: the entire header is not a target`);
}
console.log('PASS shared controller actions: scope return, disabled/lifetime guards, A/hold handoff, native focus refusal, inputs, ranges and material isolation');
// Exercise the ordinary-page branch of the actual root dispatcher, not a copied key map.
const navigationExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/GamepadNavigation.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: navigationExports });
const KeyCode = { KEYCODE_BUTTON_A: 2301, KEYCODE_BUTTON_B: 2302, KEYCODE_DPAD_DOWN: 2013 };
const modalKeys = { directionForKey: code => code === 2013 ? 'down' : '' };
const pageExports = {};
const route = source.slice(source.indexOf('  private routeGamepadKey('), source.indexOf('  private handleGamepadButton('));
vm.runInNewContext(ts.transpileModule('export class Page {\n' + route + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: pageExports, KeyCode, KeyType: { Down: 0, Up: 1 }, KeySource: { JOYSTICK: 1 },
  GamepadModalFocus: modalKeys, GamepadControls: controls, DEBUG: false });
let now = 1000, backs = 0;
const page = new pageExports.Page();
Object.assign(page, {
  gamepadPresses: new navigationExports.GamepadPressFilter(), gamepadDeviceIds: new Set([42]), gamepadSourceId: -1,
  ordinaryHat: '', ordinaryDigital: '', ordinaryDigitalAt: 0,
  getMonotonicNow: () => now, currentGamepadModal: () => null, openGamepadMenu: () => '',
  ordinaryGamepadScope: () => 'route', ordinaryGamepadBack: () => { backs++; },
});
mount('route', 'route-first', 0, 0);
mount('route', 'route-second', 0, 100);
mount('route', 'route-third', 0, 200);
controls.focus('route');
page.routeGamepadKey(2013, 0, 42, 1, 'arkui');
page.routeGamepadKey(2013, 0, 42, 1, 'arkui');
assert.ok(controls.isSelected('route', 'route-second'), 'duplicate delivery advances exactly once');
const before = actions.length;
page.routeGamepadKey(2301, 0, 42, 1, 'arkui');
assert.equal(actions.length, before, 'ordinary A waits for release so long press remains possible');
page.routeGamepadKey(2301, 1, 42, 1, 'arkui');
assert.equal(actions.at(-1), 'route-second');
page.ordinaryEditing = true; now += 100;
assert.equal(page.routeGamepadKey(2013, 0, 42, 1, 'arkui'), false, 'editing passes keyboard navigation through');
page.routeGamepadKey(2302, 0, 42, 1, 'arkui');
assert.equal(backs, 1, 'B remains owned by the app while editing');
page.systemGamepadInput = true;
assert.equal(page.routeGamepadKey(2302, 0, 42, 1, 'arkui'), false, 'external system cover owns all its input');
console.log('PASS ordinary root dispatcher: release activation, digital deduplication, editing and system-surface handoff');
// An ordinary child page must not leave the previous file toolbar highlighted.
const focusedStart = source.indexOf('  private gamepadFocused(');
const focusedEnd = source.indexOf('  private gamepadNativeFocusBox(', focusedStart);
const focusExports = {};
vm.runInNewContext(ts.transpileModule('export class FocusPage {\n' + source.slice(focusedStart, focusedEnd) + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: focusExports });
const focusPage = new focusExports.FocusPage();
Object.assign(focusPage, { gamepadModalActive: false, gamepadArea: 'filetop', gamepadItem: '返回', ordinaryGamepadScope: () => 'settings:playback' });
assert.equal(focusPage.gamepadFocused('filetop', '返回'), false);
focusPage.ordinaryGamepadScope = () => '';
assert.equal(focusPage.gamepadFocused('filetop', '返回'), true);
console.log('PASS returning focus has one owner; inactive file headers do not remain highlighted');

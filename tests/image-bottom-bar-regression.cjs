// Exercise the compiled host, including the Viewer -> Grid return handoff.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private ' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const file = 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts';
const generated = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
let callback;
function find(node) {
  if (ts.isArrowFunction(node) && node.body.getText(generated).includes("Stack.id('bottom-bar-host')") &&
      !node.body.getText(generated).includes('this.observeComponentCreation2')) callback = node;
  ts.forEachChild(node, find);
}
find(generated); assert.ok(callback, 'SDK-generated bottom bar host attributes');
let attrs;
const Stack = new Proxy({}, { get: (_, name) => value => { attrs[name] = value; } });
const exportsObject = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' + method('bottomBarLayerOpacity') + '\n' +
  method('bottomBarLayerZIndex') + '\n}\nexport function update() { const callback = ' +
  callback.getText(generated) + '; callback(1, false); }', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, Stack, Alignment: { Bottom: 1 },
  HitTestMode: { BLOCK_DESCENDANTS: 'blocked', None: 'passthrough' } });
const page = new exportsObject.Page();
const defaults = { bottomBarOpacity: 1, bottomBarOffsetY: 0, showImageViewer: false,
  viewerEntryTransitionActive: false, viewerFallbackEntryActive: false, viewerClosePending: false,
  viewerReturnOverlayVisible: false, viewerReturnOverlayBackdropOpacity: 1,
  viewerSurfaceOpacity: 1, imageDismissBackdropOpacity: 1,
  parentOverlayOwnsInteraction: () => false };
function check(state, opacity, layer, blocked = true) {
  Object.assign(page, defaults, { parentOverlayOwnsInteraction: () => blocked }, state);
  attrs = {}; exportsObject.update.call(page);
  assert.ok(Math.abs(attrs.opacity - opacity) < 1e-6, JSON.stringify(state));
  assert.equal(attrs.zIndex, layer);
  assert.equal(attrs.hitTestBehavior, blocked ? 'blocked' : 'passthrough');
  assert.equal(attrs.id, 'bottom-bar-host');
}
check({}, 1, 20, false);
check({ viewerEntryTransitionActive: true }, 1, 35);
check({ showImageViewer: true }, 0, 35);
for (const backdrop of [1, .75, .4, 0, .4, 1]) {
  check({ showImageViewer: true, imageDismissBackdropOpacity: backdrop }, 1 - backdrop, 35);
}
for (const surface of [0, .5, 1]) {
  check({ showImageViewer: true, viewerFallbackEntryActive: true, viewerSurfaceOpacity: surface }, 1 - surface, 35);
}
// Atomic Grid handoff must use its own backdrop even if the Viewer was retained.
for (const backdrop of [1, .5, 0]) {
  check({ showImageViewer: true, viewerReturnOverlayVisible: true,
    viewerReturnOverlayBackdropOpacity: backdrop }, 1 - backdrop, 35);
}
check({ viewerClosePending: true }, 1, 35);
check({}, 1, 20, false); // finishing close must not dip or remount the host
check({ showImageViewer: true, imageDismissBackdropOpacity: 0, bottomBarOpacity: 0 }, 0, 35);
check({ bottomBarOpacity: .5 }, .5, 20, false);
check({ showAudioPlayer: true }, 1, 20);
check({ showVideoPlayer: true }, 1, 20);
console.log('PASS compiled bottom bar host: shared occlusion layer, pull/cancel, entry, Grid handoff, unchanged input ownership and other scenes');

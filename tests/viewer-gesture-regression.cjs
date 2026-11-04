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
const constants = [...source.matchAll(/^const (IMAGE_DISMISS_\w+): number = ([0-9.]+)$/gm)]
  .map(m => 'const ' + m[1] + '=' + m[2] + ';').join('\n');
const swiper = source.match(/\.disableSwipe\((this\.viewerGestureBlocked\(\)[^\n]+)\)/);
assert.ok(swiper, 'Swiper uses the same common gesture gates');
const exportsObject = {};
const names = ['viewerGestureBlocked', 'imageDismissGestureEnabled', 'imageDismissProgress',
  'handleImageDismissStart', 'handleImageDismissUpdate', 'handleImageDismissEnd',
  'handleImageDismissCancel', 'startImageDismissClose'];
vm.runInNewContext(ts.transpileModule(constants + '\nexport class Page {\n' +
  names.map(method).join('\n') + '\nswipeBlocked() { return ' + swiper[1] + '; }\n}', { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports: exportsObject });
function page() {
  const p = new exportsObject.Page();
  Object.assign(p, { showImageViewer: true, viewerClosePending: false, viewerTransitionActive: false,
    viewerEntryTransitionActive: false, isBusy: false, showImageMoreMenu: false,
    continuationDialogCount: 0, showRenameDialog: false, viewerImageIndex: 0, imageScale: 1,
    imageAnalyzerActive: false, imageDismissDragging: false, imageViewportHeightVp: 800,
    imageChromeVisible: true, imageTouchLastX: 200, closeCount: 0, restoreCount: 0,
    setImageChromeVisible() {}, closeImageViewer() { this.closeCount++; },
    animateImageDismissBack() { this.restoreCount++; }
  });
  return p;
}
let p = page();
assert.equal(p.swipeBlocked(), false); assert.equal(p.imageDismissGestureEnabled(0), true);
for (const [key, value] of [['showImageViewer', false], ['viewerClosePending', true],
  ['viewerTransitionActive', true], ['viewerEntryTransitionActive', true], ['isBusy', true],
  ['showImageMoreMenu', true], ['continuationDialogCount', 1], ['showRenameDialog', true]]) {
  p = page(); p[key] = value;
  assert.equal(p.swipeBlocked(), true, key + ' blocks paging');
  assert.equal(p.imageDismissGestureEnabled(0), false, key + ' blocks dismiss admission');
  p.handleImageDismissStart(0); assert.equal(p.imageDismissDragging, false);
}
p = page(); p.imageScale = 2;
assert.equal(p.swipeBlocked(), true); assert.equal(p.imageDismissGestureEnabled(0), false);
p = page(); p.imageScale = 1.001;
assert.equal(p.swipeBlocked(), false); assert.equal(p.imageDismissGestureEnabled(0), true);
p = page(); assert.equal(p.imageDismissGestureEnabled(1), false, 'a cached neighbor cannot start dismiss');
p.imageAnalyzerActive = true;
assert.equal(p.imageDismissGestureEnabled(0), false, 'text selection retains vertical dragging');
assert.equal(p.swipeBlocked(), false, 'horizontal analyzer behavior is preserved, not blindly unified');
p = page(); p.handleImageDismissStart(0);
assert.equal(p.imageDismissDragging, true); assert.equal(p.imageDismissAnchorX, 200);
assert.equal(p.swipeBlocked(), true, 'Swiper yields once vertical drag has been admitted');
p.viewerTransitionActive = true; p.isBusy = true;
p.handleImageDismissUpdate(0, { offsetY: 200 });
assert.equal(p.imageDismissOffsetY, 200, 'accepted drag continues despite diagonal Swiper state changes');
assert.ok(p.imageDismissScale < 1);
p.handleImageDismissUpdate(0, { offsetY: -20 });
assert.ok(Math.abs(p.imageDismissOffsetY + 3.6) < 0.00001, 'reverse movement keeps the existing resistance');
p.handleImageDismissUpdate(0, { offsetY: 300 });
p.handleImageDismissEnd(0, { velocityY: 0 });
assert.equal(p.closeCount, 1); assert.equal(p.imageDismissDragging, false);
p.handleImageDismissEnd(0, { velocityY: 0 }); assert.equal(p.closeCount, 1, 'end cannot close twice');
p = page(); p.handleImageDismissStart(0); p.handleImageDismissUpdate(0, { offsetY: 10 });
p.handleImageDismissEnd(0, { velocityY: 0 }); assert.equal(p.closeCount, 0); assert.equal(p.restoreCount, 1);
p = page(); p.handleImageDismissStart(0); p.handleImageDismissCancel();
assert.equal(p.imageDismissDragging, false); assert.equal(p.restoreCount, 1);
p.handleImageDismissEnd(0, { velocityY: 2000 }); assert.equal(p.closeCount, 0);
assert.doesNotMatch(method('handleImageDismissUpdate'), /viewerGestureBlocked|imageDismissGestureEnabled/,
  'common admission checks must not be reapplied to an accepted drag');
console.log('PASS viewer gesture gates: shared blocking states, busy/close rejection, scale/page/analyzer differences, Swiper yield, continuous diagonal drag, reverse resistance, close/restore/cancel and no double close');

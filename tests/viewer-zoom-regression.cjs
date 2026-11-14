// Exercise the actual focal zoom handlers and transform commit.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const exportsObject = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' +
  ['handleImageDoubleTap', 'imageZoomOffset', 'animateImageTransform', 'viewerGestureBlocked',
    'handleImagePinchStart', 'handleImagePinchUpdate', 'handleImagePinchEnd',
    'handleImagePanEnd', 'handleImagePanCancel', 'clampImageOffset', 'normalizeImageTransform',
    'resetImageTransform', 'resetImageDismissTransform', 'handleImageViewportArea'].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, Curve: { FastOutSlowIn: 'zoom' } });
function make(width = 800, height = 1200) {
  const p = new exportsObject.Page(), animations = [];
  Object.assign(p, { imageScale: 1, imageOffsetX: 0, imageOffsetY: 0,
    imageViewportWidthVp: width, imageViewportHeightVp: height, showImageViewer: true,
    viewerClosePending: false, viewerTransitionActive: false, viewerEntryTransitionActive: false,
    isBusy: false, showImageMoreMenu: false, continuationDialogCount: 0, showRenameDialog: false,
    imageDismissDragging: false, imagePinchActive: false, viewerImageIndex: 0, cancelImageLongPressWatch() {},
    getUIContext: () => ({ animateTo(options, action) { animations.push(options); action(); } }) });
  return { p, animations };
}
const point = (x, y) => ({ localX: x, localY: y, globalX: x + 300, globalY: y + 150 });
function tap(t, x, y) { t.p.handleImageDoubleTap({ fingerList: [point(x, y)] }); }
for (const [width, height] of [[400, 850], [1200, 800], [500, 400], [800, 1200]]) {
  for (const [fx, fy] of [[0.5, 0.5], [0.15, 0.25], [0.85, 0.75], [0, 0], [1, 1]]) {
    const t = make(width, height), x = width * fx, y = height * fy;
    const sourceX = x - width / 2, sourceY = y - height / 2;
    tap(t, x, y);
    assert.equal(t.p.imageScale, 2);
    assert.ok(Math.abs(width / 2 + sourceX * t.p.imageScale + t.p.imageOffsetX - x) < 1e-6,
      'tapped source pixel stays fixed horizontally in phone/tablet/split-window viewports');
    assert.ok(Math.abs(height / 2 + sourceY * t.p.imageScale + t.p.imageOffsetY - y) < 1e-6);
    assert.equal(t.animations[0].duration, 180, 'retain the existing animation duration');
    assert.equal(t.p.imageSavedScale, 2);
    assert.equal(t.p.imageSavedOffsetX, t.p.imageOffsetX);
    assert.equal(t.p.imageSavedOffsetY, t.p.imageOffsetY);
    tap(t, width - x, height - y);
    assert.deepEqual([t.p.imageScale, t.p.imageOffsetX, t.p.imageOffsetY], [1, 0, 0],
      'next double tap restores the base frame regardless of tap position');
  }
}
let t = make(); t.p.handleImageDoubleTap({ fingerList: [undefined, point(200, 300)] });
assert.deepEqual([t.p.imageOffsetX, t.p.imageOffsetY], [200, 300], 'sparse finger IDs are valid');
for (const fingerList of [[], [point(NaN, 2)], [point(1, Infinity)]]) {
  t = make(); t.p.handleImageDoubleTap({ fingerList });
  assert.deepEqual([t.p.imageOffsetX, t.p.imageOffsetY], [0, 0], 'non-pointer/invalid input retains centered zoom');
}
t = make(); tap(t, -10, 1400);
assert.deepEqual([t.p.imageOffsetX, t.p.imageOffsetY], [400, -600], 'clamp an out-of-bounds event to the page');
t = make(); t.p.imageScale = 1.001; t.p.imageOffsetX = 0.2; t.p.imageOffsetY = -0.1;
const x = 160, y = 200;
const sourceX = (x - 400 - t.p.imageOffsetX) / t.p.imageScale;
const sourceY = (y - 600 - t.p.imageOffsetY) / t.p.imageScale;
tap(t, x, y);
assert.ok(Math.abs(400 + sourceX * 2 + t.p.imageOffsetX - x) < 1e-6);
assert.ok(Math.abs(600 + sourceY * 2 + t.p.imageOffsetY - y) < 1e-6, 'small prior transforms do not shift the focal pixel');
for (const [key, value] of [['showImageViewer', false], ['viewerClosePending', true],
  ['viewerTransitionActive', true], ['viewerEntryTransitionActive', true], ['isBusy', true],
  ['showImageMoreMenu', true], ['continuationDialogCount', 1], ['showRenameDialog', true],
  ['imageDismissDragging', true], ['imagePinchActive', true]]) {
  t = make(); t.p[key] = value; tap(t, 200, 300);
  assert.equal(t.animations.length, 0, key + ' must block a new zoom');
}
assert.match(source, /this\.handleImageDoubleTap\(event\)/, 'native double-tap callback passes its event');

const pinch = (scale, pinchCenterX, pinchCenterY) => ({ scale, pinchCenterX, pinchCenterY });
const pose = p => [p.imageScale, p.imageOffsetX, p.imageOffsetY];
for (const [base, offsetX, offsetY, gestureScale] of [[1, 0, 0, 2], [3, 90, -120, 0.7], [2, 0, 0, 5]]) {
  const { p } = make();
  Object.assign(p, { imageScale: base, imageOffsetX: offsetX, imageOffsetY: offsetY });
  p.handleImagePinchStart(0, pinch(1, 250, 400));
  const sx = (250 - 400 - offsetX) / base, sy = (400 - 600 - offsetY) / base;
  for (const [x, y] of [[250, 400], [320, 510], [275, 440]]) {
    p.handleImagePinchUpdate(0, pinch(gestureScale, x, y));
    assert.equal(p.imageScale, Math.min(5, base * gestureScale));
    assert.ok(Math.abs(400 + sx * p.imageScale + p.imageOffsetX - x) < 1e-6,
      'the same source pixel follows the moving pinch midpoint horizontally');
    assert.ok(Math.abs(600 + sy * p.imageScale + p.imageOffsetY - y) < 1e-6);
  }
  const before = pose(p);
  p.handleImagePanEnd(0, { velocityX: 500, velocityY: 300 });
  p.handleImagePanCancel(0);
  p.handleImagePinchEnd(1);
  assert.equal(p.imagePinchActive, true);
  assert.deepEqual(pose(p), before, 'parallel pan and cached pages cannot replace the active pinch');
  p.handleImagePinchEnd(0);
  assert.deepEqual(pose(p), before, 'release does not jump for a valid pinch pose');
  assert.equal(p.imagePinchActive, false);
  assert.deepEqual([p.imageSavedScale, p.imageSavedOffsetX, p.imageSavedOffsetY], before);
}
t = make();
t.p.handleImagePinchStart(0, pinch(1, 250, 400));
t.p.handleImagePinchUpdate(0, pinch(2, 800, 1200));
assert.deepEqual(pose(t.p), [2, 400, 600], 'pinch movement respects viewport edges');
t.p.handleImagePinchUpdate(0, pinch(0, 800, 1200));
assert.deepEqual(pose(t.p), [1, 0, 0], 'the base scale is centered during the gesture');
t.p.handleImagePinchUpdate(0, pinch(NaN, 200, 300));
assert.deepEqual(pose(t.p), [1, 0, 0]);
t.p.handleImageViewportArea({ width: 1200, height: 800 });
t.p.handleImagePinchUpdate(0, pinch(2, 200, 300));
assert.equal(t.p.imagePinchActive, false);
assert.deepEqual(pose(t.p), [1, 0, 0], 'old touch updates cannot use the new viewport with a stale anchor');
assert.match(source, /\.onActionCancel\(\(\) => this\.handleImagePinchEnd\(index\)\)/,
  'native cancellation clears the same pinch state as release');
console.log('PASS viewer focal zoom: fixed and moving focal pixels, zoom limits, edge normalization, pan arbitration, cancellation and resize');

// node tests/grid-return-resize-regression.cjs <SDK typescript.js>
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const names = ['recordFilePageSize', 'updateFilePageSize', 'mediaReturnBandTop', 'mediaReturnBandBottom',
  'gridViewerReturnTargetVisible', 'waitForFileViewport', 'scrollMediaReturnSourceIntoView',
  'scrollItemIntoContentBand', 'prepareMediaReturnSource', 'closeGridViewerWithReturnOverlay'];
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const layoutExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/FileGridLayout.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: layoutExports });
class ViewerReturnSnapshot { constructor() { this.target = {}; } }
const exportsObject = {};
vm.runInNewContext(ts.transpileModule('export class Harness {\n' + names.map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, console: { info() {}, warn() {} }, ViewerReturnSnapshot,
  Math, Promise, setTimeout, FileGridLayout: layoutExports.FileGridLayout, IMAGE_RETURN_MOUNT_FRAME_LIMIT: 8, IMAGE_GEOMETRY_TRANSITION_DURATION: 240,
  IMAGE_FALLBACK_TRANSITION_DURATION: 160, ScrollAlign: { AUTO: 3 }, Curve: { FastOutSlowIn: 1 } });
const entry = { path: '/photos/current.jpg' };
function make() {
  const h = new exportsObject.Harness(), events = [], animations = [];
  const state = { thumbnailX: 100, thumbnailY: 200, thumbnailWidth: 120, thumbnailHeight: 120,
    thumbnailSurface: 'grid', thumbnailVisibleRatio: 1 };
  let mounted = true;
  Object.assign(h, { screen: 'files', showSearch: false, fileViewMode: 'grid', entries: [entry],
    canAnchorGridViewport: () => false,
    pageWidthVp: 800, pageHeightVp: 1200, fileViewportVersion: 0, viewerReturnViewportVersion: 0,
    fileScrollViewport: { x: 0, y: 0, width: 800, height: 1200 }, targetLocateEntryPath: '',
    fileContentTopInset: () => 100, floatingBarContentInset: () => 76, bottomSafeInset: () => 0,
    viewerGeneration: 1, viewerReturnOverlayToken: 0, viewerClosePending: true, showImageViewer: true, closeSessionId: 1,
    viewerImageEntry: entry, imageViewportWidthVp: 800, imageViewportHeightVp: 1200,
    viewerCurrentFramePath: entry.path, viewerCurrentFrame: { x: 0, y: 100, width: 800, height: 1000 },
    viewerLayerOriginX: 0, viewerLayerOriginY: 0, viewerImageIndex: 0, viewerSurfaceOpacity: 1,
    imageDismissBackdropOpacity: 1, getMonotonicNow: () => 1,
    viewerImageSource: () => 'borrowed-raster', viewerImageSourceOrientation: () => 0,
    viewerImageFit: () => 1, viewerImageFrameAspectRatio: () => 0.8, viewerPageVisualScale: () => 1,
    viewerPageOffsetX: () => 0, viewerPageOffsetY: () => 0,
    refreshGridThumbnailArea: () => mounted, imageVisualState: () => state,
    nextRenderFrame: async () => { events.push(['frame']); },
    restoreImageViewerOrientation: async () => { events.push(['orientation']); },
    notifyEntryChanged: path => events.push(['notify', path]), clearViewerEntryTransition() {},
    logViewerReturnOverlay(stage) { if (stage === 'request') events.push(['target', h.viewerReturnSnapshot]); },
    onMount() {},
    tapTrace() {}, finishCloseImageViewer() { h.viewerClosePending = false; events.push(['closed']); },
    getUIContext: () => ({ animateTo(options, action) { action(); animations.push({ duration: options.duration,
      x: h.viewerReturnOverlayX, y: h.viewerReturnOverlayY, width: h.viewerReturnOverlayWidth }); options.onFinish(); } })
  });
  h.fileListScroller = {
    getItemRect() { throw Error('whole GridItem rectangle must not determine thumbnail alignment'); },
    scrollToIndex(index, smooth, align) { events.push(['index', index, smooth, align]); mounted = true; state.thumbnailY = 650; },
    scrollBy(x, delta) { events.push(['by', x, delta]); state.thumbnailY -= delta; }
  };
  let overlay = false;
  Object.defineProperty(h, 'viewerReturnOverlayVisible', { get: () => overlay, set(value) {
    overlay = value;
    if (value) queueMicrotask(() => { h.onMount(); h.viewerReturnOverlayMountResolve(); });
  } });
  return { h, state, events, animations, mount(value) { mounted = value; },
    resize(width, height) { h.recordFilePageSize({ width, height }); h.fileScrollViewport.width = width; h.fileScrollViewport.height = height; } };
}
const movements = t => t.events.filter(e => ['by', 'index'].includes(e[0]));
(async () => {
  let t = make();
  t.h.recordFilePageSize({ width: 800, height: 1200 }); assert.equal(t.h.fileViewportVersion, 0);
  t.resize(1200, 800); assert.equal(t.h.fileViewportVersion, 1);
  t.resize(800, 1200); assert.equal(t.h.fileViewportVersion, 2, 'rotate away/back still invalidates old geometry');

  t = make(); await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.deepEqual(movements(t), []); assert.equal(t.events.some(e => e[0] === 'frame'), false,
    'normal return must keep its existing fast path');
  assert.equal(t.animations[0].duration, 240); assert.equal(t.events.filter(e => e[0] === 'orientation').length, 1);
  t = make(); t.mount(false); await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.deepEqual(movements(t), []); assert.equal(t.animations[0].duration, 160,
    'an ordinary offscreen return retains its existing fade fallback');

  t = make(); t.state.thumbnailY = 900; t.resize(1200, 800);
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.deepEqual(movements(t), [['by', 0, 296]], 'minimal distance to the new bottom band, never center');
  assert.equal(t.animations[0].y, 604); assert.equal(t.animations[0].duration, 240);
  assert.equal(t.h.viewerClosePending, false); assert.equal(t.h.showImageViewer, false);
  const movesAfterClose = movements(t).length; await new Promise(r => setTimeout(r, 65));
  assert.equal(movements(t).length, movesAfterClose, 'no delayed scroll can interfere with the first file-page gesture');

  t = make(); t.h.pageWidthVp = 1200; t.h.pageHeightVp = 800;
  t.h.fileScrollViewport.width = 1200; t.h.fileScrollViewport.height = 800;
  t.state.thumbnailY = 700; t.resize(800, 1200);
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.deepEqual(movements(t), [], 'a taller return viewport must not reposition a now-visible image');

  t = make(); t.resize(1200, 800); t.state.thumbnailY = 50;
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.deepEqual(movements(t), [['by', 0, -50]], 'align the thumbnail, excluding the first-row GridItem inset');
  t = make(); t.resize(1200, 800); t.state.thumbnailVisibleRatio = 0;
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.deepEqual(movements(t), []); assert.equal(t.animations[0].duration, 240,
    'fresh geometry after resize must not depend on a stale visibility callback');

  t = make(); t.resize(1200, 800); t.mount(false);
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.deepEqual(movements(t), [['index', 0, false, 3], ['by', 0, 46]],
    'unmounted target: native minimal mounting, then exact thumbnail correction');
  assert.equal(t.animations[0].y, 604);

  t = make(); t.resize(1200, 800); t.state.thumbnailY = 900;
  let pending = 0, frames = 0;
  t.h.fileListScroller.scrollBy = (_x, delta) => { t.events.push(['by', 0, delta]); pending += delta; };
  t.h.nextRenderFrame = async () => { frames++; if (frames === 4) { t.state.thumbnailY -= pending; pending = 0; } };
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.equal(movements(t).length, 1, 'pre-layout frames cannot apply the same correction twice');

  t = make(); t.resize(1200, 800); let count = 0;
  t.h.nextRenderFrame = async () => { count++; if (count === 1) t.resize(1000, 700); };
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.ok(count >= 3, 'wait for the final viewport before freezing its target');
  t = make(); t.resize(1200, 800); count = 0;
  t.h.nextRenderFrame = async () => { count++; t.h.fileViewportVersion++; };
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.equal(count, 8); assert.equal(t.animations[0].duration, 160, 'unstable layout has a bounded fade fallback');
  assert.deepEqual(movements(t), []);

  t = make(); t.resize(1200, 800);
  t.h.nextRenderFrame = async () => { t.h.viewerImageEntry = null; };
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.deepEqual(movements(t), []); assert.equal(t.animations.length, 0, 'cancelled preparation cannot touch another page');
  t = make(); t.resize(1200, 800); t.h.onMount = () => { t.h.fileViewportVersion++; };
  await t.h.closeGridViewerWithReturnOverlay(entry, false);
  assert.equal(t.animations[0].duration, 160, 'a resized handoff cannot fly to its frozen old target');
  t = make(); t.resize(1200, 800); t.mount(false);
  const latest = { path: '/photos/latest-after-swipe.jpg' };
  t.h.entries = [entry, latest]; t.h.viewerImageEntry = latest; t.h.viewerCurrentFramePath = latest.path;
  await t.h.closeGridViewerWithReturnOverlay(latest, false);
  assert.deepEqual(movements(t)[0], ['index', 1, false, 3], 'locate the current image after swiping, not the entry image');
})().then(() => console.log('PASS: grid resize return — stable fast path, exact minimum scroll, lazy mount, bounded layout wait, cancellation and no late scroll'))
.catch(error => { console.error(error); process.exitCode = 1; });

// Use actual page admission/preparation/binding methods for clipped WaterFlow cards.
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
vm.runInNewContext(ts.transpileModule('export class Page {\n' + [
  'thumbnailIntersectsFileViewport', 'hasViewerTransitionSource', 'viewerReturnSourceReady',
  'prepareMediaReturnSource', 'prepareViewerReturnSource', 'startViewerExitTransition',
  'viewerReturnTargetVisible', 'mediaReturnBandTop', 'mediaReturnBandBottom', 'mediaReturnScrollDelta'
].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, IMAGE_RETURN_MOUNT_FRAME_LIMIT: 8 });
const entry = { path: '/photos/tall.jpg' };
function make() {
  const p = new exportsObject.Page(), state = {
    thumbnailSurface: 'waterfall', thumbnailX: 100, thumbnailY: -120,
    thumbnailWidth: 300, thumbnailHeight: 800, thumbnailVisibleRatio: 0.6,
    transitionThumbnailUri: 'cached', displayWidth: 600, displayHeight: 1600
  };
  Object.assign(p, { screen: 'files', showSearch: false, fileViewMode: 'waterfall',
    showImageViewer: true, viewerImageEntry: entry, waterfallEntries: [entry],
    viewerPreviewBitmaps: { [entry.path]: {} }, fileScrollViewport: { x: 0, y: 0, width: 800, height: 600 },
    pageWidthVp: 800, pageHeightVp: 600, isImage: () => true,
    refreshGridThumbnailArea: () => true, imageVisualState: () => state,
    thumbnailSurfaceUri: () => 'cached', thumbnailSurfaceIsCurrent: () => true,
    fileContentTopInset: () => 100, topSafeInset: () => 20, bottomSafeInset: () => 0, floatingBarContentInset: () => 76,
    currentThumbnailSurface: () => state.thumbnailSurface,
    ensured: 0, prepared: 0, frames: 0, moves: 0,
    ensureWaterfallIndex: async () => { p.ensured++; }, waterfallLocalIndex: () => 0,
    ensureViewerPreviewBitmap: async () => { p.prepared++; p.viewerPreviewBitmaps[entry.path] = {}; },
    scrollMediaReturnSourceIntoView() { p.moves++; state.thumbnailY = 100; return true; },
    nextRenderFrame: async () => { p.frames++; }, clearViewerEntryTransition() {}, traceStateWrite() {}
  });
  return { p, state };
}
(async () => {
  let t = make();
  assert.equal(t.p.hasViewerTransitionSource(entry, true), false, 'a tall card cannot satisfy full-visibility admission');
  assert.equal(await t.p.prepareViewerReturnSource(entry), true);
  assert.deepEqual([t.p.moves, t.p.frames, t.p.prepared], [0, 0, 1], 'clipped card prepares its raster without scrolling or waiting');
  assert.equal(t.p.viewerReturnReadyPath, entry.path);
  assert.equal(t.p.startViewerExitTransition(entry, 'original'), true, 'exit binding uses the same partial-visibility rule');
  assert.equal(t.p.viewerTransitionKind, 'exit'); assert.equal(t.p.viewerTransitionLayer, 'original');
  t = make(); t.p.viewerPreviewBitmaps = {};
  assert.equal(await t.p.prepareViewerReturnSource(entry), true);
  assert.equal(t.p.moves, 0, 'missing preview raster is prepared before deciding whether to scroll');
  t = make(); t.state.thumbnailVisibleRatio = 0; t.state.thumbnailY = 599;
  assert.equal(await t.p.prepareViewerReturnSource(entry), true, 'current intersection can precede the visibility callback');
  assert.equal(t.p.moves, 0);
  for (const [x, y] of [[100, 600], [100, -800], [-300, 20], [800, 20]]) {
    t = make(); t.state.thumbnailX = x; t.state.thumbnailY = y;
    assert.equal(t.p.viewerReturnSourceReady(entry), false, 'no actual overlap cannot bind a stale source');
  }
  t = make(); t.state.thumbnailY = 700;
  assert.equal(await t.p.prepareViewerReturnSource(entry), true);
  assert.deepEqual([t.p.moves, t.p.frames, t.p.prepared], [1, 1, 1], 'offscreen recovery retains the bounded existing locator and prepares only once');
  t = make(); t.state.transitionThumbnailUri = 'old';
  assert.equal(t.p.viewerReturnSourceReady(entry), false, 'partial visibility does not relax URI identity');
  assert.equal(await t.p.prepareViewerReturnSource(entry), false);
  assert.equal(t.p.moves, 0, 'a visible image with an unavailable raster must not reposition the directory');
  t = make(); t.p.viewerPreviewBitmaps = {};
  assert.equal(t.p.viewerReturnSourceReady(entry), false, 'a source raster remains required');
  t = make(); t.p.thumbnailSurfaceIsCurrent = () => false;
  assert.equal(t.p.viewerReturnSourceReady(entry), false);
  for (const surface of ['list', 'grid']) {
    t = make(); t.state.thumbnailSurface = surface; t.p.fileViewMode = surface;
    assert.equal(t.p.viewerReturnSourceReady(entry), true, surface + ' uses the same partial-image rule');
    assert.equal(await t.p.prepareViewerReturnSource(entry), true);
    assert.deepEqual([t.p.moves, t.p.frames], [0, 0], surface + ' prepares the raster without repositioning');
  }
  for (const surface of ['list', 'waterfall']) {
    t = make(); t.state.thumbnailSurface = surface; t.p.fileViewMode = surface;
    t.state.thumbnailHeight = 120; t.state.thumbnailY = 700;
    t.p.scrollMediaReturnSourceIntoView = () => {
      t.p.moves++; t.state.thumbnailY = t.p.moves === 1 ? 599 : 404; return true;
    };
    assert.equal(await t.p.prepareViewerReturnSource(entry), true);
    assert.deepEqual([t.p.moves, t.p.frames], [2, 3], surface + ' must finish full exposure after initially mounting only one pixel');
    assert.equal(t.state.thumbnailY, 404);
  }
  t = make(); t.state.thumbnailSurface = 'grid'; t.p.fileViewMode = 'grid';
  t.state.thumbnailHeight = 120; t.state.thumbnailY = 700;
  assert.equal(await t.p.prepareViewerReturnSource(entry), false);
  assert.equal(t.p.moves, 0, 'Grid swipe prewarming must not introduce background scrolling');
  t.p.viewerClosePending = true;
  assert.equal(await t.p.prepareViewerReturnSource(entry), true);
  assert.equal(t.p.moves, 1, 'actual Grid close enables offscreen recovery');
  t = make(); t.state.thumbnailHeight = 120; t.state.thumbnailY = 700;
  t.p.ensureWaterfallIndex = async () => { t.state.thumbnailY = 599; };
  assert.equal(await t.p.prepareViewerReturnSource(entry), true);
  assert.equal(t.p.moves, 1, 'group mounting cannot erase the original offscreen-recovery decision');
  for (const [top, expected] of [[700, 600], [-900, -624], [-50, 0]]) {
    t = make();
    assert.equal(t.p.mediaReturnScrollDelta(top, 800), expected, 'oversized cards maximize exposure without alternating edges');
  }
  t = make(); t.state.thumbnailSurface = 'search';
  assert.equal(t.p.viewerReturnSourceReady(entry), false, 'search keeps its previous full-visibility policy');
  for (const phase of ['ensure', 'raster']) {
    t = make();
    if (phase === 'ensure') t.p.ensureWaterfallIndex = async () => { t.p.viewerImageEntry = null; };
    else t.p.ensureViewerPreviewBitmap = async () => { t.p.viewerImageEntry = null; };
    assert.equal(await t.p.prepareViewerReturnSource(entry), false);
    assert.equal(t.p.moves, 0, 'cancellation cannot reposition another scene');
  }
  console.log('PASS waterfall return: clipped/tall cards fly in place, shared binding gate, raster preparation ordering, URI identity, offscreen recovery and cancellation');
})().catch(error => { console.error(error); process.exitCode = 1; });

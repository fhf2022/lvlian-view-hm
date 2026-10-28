// Run with Node and the SDK TypeScript module path as the first argument.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const names = ['gridThumbnailComponentId', 'gridTileComponentId', 'gridEntryUsesFileTile', 'refreshGridThumbnailArea',
  'hasViewerTransitionSource', 'updateDragSelectionHit', 'audioThumbnailIconSize'];
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const rest = source.slice(start + 1);
  const end = rest.search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const exportsObject = {};
vm.runInNewContext(ts.transpileModule('export class Harness {\n' +
  names.map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, console, DEBUG: false });

const entry = { path: '/photos/image.jpg' };
function make() {
  const h = new exportsObject.Harness();
  const state = { thumbnailX: 900, thumbnailY: 900, thumbnailWidth: 30, thumbnailHeight: 30,
    thumbnailVisibleRatio: 1, thumbnailSurface: 'grid', transitionThumbnailUri: 'cached',
    displayWidth: 512, displayHeight: 384 };
  let rect = { size: { width: 282, height: 282 }, windowOffset: { x: 578, y: 808 } };
  const queried = [];
  Object.assign(h, {
    screen: 'files', showSearch: false, fileViewMode: 'grid', entries: [entry],
    getUIContext: () => ({ px2vp: n => n / 2, getComponentUtils: () => ({
      getRectangleById(id) { queried.push(id); if (!rect) throw new Error('unmounted'); return rect; }
    }) }),
    recordThumbnailArea: (_entry, index, surface, area) => Object.assign(state, {
      thumbnailIndex: index, thumbnailSurface: surface, thumbnailX: area.globalPosition.x,
      thumbnailY: area.globalPosition.y, thumbnailWidth: area.width, thumbnailHeight: area.height
    }),
    recordRowHitArea() {}, isImage: () => true, isVideo: () => false, imageVisualState: () => state,
    thumbnailSurfaceUri: () => 'cached', thumbnailSurfaceIsCurrent: () => true,
    fileContentTopInset: () => 100, topSafeInset: () => 20, bottomSafeInset: () => 0,
    pageHeightVp: 900, viewerPreviewBitmaps: { [entry.path]: {} }
  });
  return { h, state, queried, setRect: value => { rect = value; } };
}

let t = make();
assert.equal(t.h.hasViewerTransitionSource(entry, true), true);
assert.deepEqual([t.state.thumbnailX, t.state.thumbnailY, t.state.thumbnailWidth,
  t.state.thumbnailHeight], [289, 404, 141, 141], 'use the actual mounted rect and convert px to vp');
assert.equal(t.queried[0], 'file-grid-thumbnail:' + entry.path);
t.setRect({ size: { width: 400, height: 400 }, windowOffset: { x: 100, y: 300 } });
assert.equal(t.h.hasViewerTransitionSource(entry, true), true);
assert.equal(t.state.thumbnailY, 150, 'resize or scrolling cannot reuse the previous window coordinate');
t.setRect(null);
assert.equal(t.h.hasViewerTransitionSource(entry, true), false,
  'a previously visible but now unmounted image cannot fly to its stale rectangle');
t.setRect({ size: { width: 0, height: 0 }, windowOffset: { x: 0, y: 0 } });
assert.equal(t.h.hasViewerTransitionSource(entry, false), false, 'reject a not-yet-laid-out cell');
t.setRect({ size: { width: 282, height: 282 }, windowOffset: { x: 578, y: -100 } });
assert.equal(t.h.hasViewerTransitionSource(entry, true), false, 'do not return behind the header');
t = make();
t.h.entries = [{ path: '/other.jpg' }, entry];
assert.equal(t.h.refreshGridThumbnailArea(entry, 0), false, 'reject a stale index after data reorder');
assert.equal(t.h.refreshGridThumbnailArea(entry), true);
assert.equal(t.state.thumbnailIndex, 1);
for (const mode of ['list', 'waterfall']) {
  t = make(); t.h.fileViewMode = mode;
  assert.equal(t.h.refreshGridThumbnailArea(entry), true);
  assert.equal(t.queried.length, 0, 'other surfaces keep their existing geometry provider');
}
t = make(); t.h.showSearch = true;
assert.equal(t.h.refreshGridThumbnailArea(entry), true);
assert.equal(t.queried.length, 0);

const hits = [], points = [];
Object.assign(t.h, {
  dragSurface: 'grid', dragSelectionScrollRunning: false, dragSelectionX: 215, dragSelectionY: 340,
  fileScrollViewport: { x: 15, y: 40, width: 600, height: 700 },
  dragSelectionBandTop: () => 100, dragSelectionBandBottom: () => 650,
  dragSelectionEntries: () => [{}, {}, {}],
  dragSelectionScroller: () => ({ getItemIndex: (x, y) => { points.push([x, y]); return 2; } }),
  applyDragSelectionHit: index => hits.push(index)
});
t.h.updateDragSelectionHit();
assert.deepEqual(points, [[200, 300]], 'hit-test using container-local vp, not window coordinates');
assert.deepEqual(hits, [2], 'grid selection can hit an item without per-row geometry records');
t.h.dragSelectionScroller = () => ({ getItemIndex: () => -1 });
t.h.updateDragSelectionHit();
assert.deepEqual(hits, [2], 'a gap must not select a distant or stale row');

t = make();
let tileArea;
t.h.isImage = () => false;
t.h.getUIContext = () => ({ px2vp: n => n / 2, getComponentUtils: () => ({
  getRectangleById: id => id.startsWith('file-grid-tile:')
    ? { size: { width: 282, height: 282 }, windowOffset: { x: 578, y: 808 } }
    : { size: { width: 96, height: 96 }, windowOffset: { x: 672, y: 870 } }
}) });
t.h.recordRowHitArea = (_e, _i, _surface, area) => { tileArea = area; };
assert.equal(t.h.refreshGridThumbnailArea(entry), true);
assert.deepEqual([t.state.thumbnailWidth, t.state.thumbnailHeight], [48, 48],
  'audio shared-element flights use the inner artwork');
assert.deepEqual([tileArea.width, tileArea.height, tileArea.globalPosition.x], [141, 141, 289],
  'the lifted context menu uses the complete named tile');
t = make(); t.h.isImage = () => false; t.h.isVideo = () => true;
assert.equal(t.h.refreshGridThumbnailArea(entry), true);
assert.equal(t.queried.length, 1, 'video geometry still uses the original full-square cover ID');
assert.equal(t.state.thumbnailWidth, 141);
t.h.audioOriginSurface = 'grid';
assert.equal(t.h.audioThumbnailIconSize({ width: 81, height: 81 }), 81,
  'default audio artwork uses the measured adaptive icon width for opening and returning');
for (const surface of ['list', 'search']) {
  t.h.audioOriginSurface = surface;
  assert.equal(t.h.audioThumbnailIconSize({ width: 40, height: 34 }), 32);
}
console.log('Grid geometry regression passed');

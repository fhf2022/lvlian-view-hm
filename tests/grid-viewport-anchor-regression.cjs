// node tests/grid-viewport-anchor-regression.cjs <SDK typescript.js>
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const layoutExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/FileGridLayout.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: layoutExports });
const exportsObject = {};
vm.runInNewContext(ts.transpileModule('export class H {' +
  ['recordFilePageSize', 'updateFilePageSize', 'canAnchorGridViewport', 'gridViewportAnchorIsCurrent', 'gridViewportHasCurrentSize',
    'createGridViewportAnchor', 'rememberGridViewportAnchor', 'restoreGridViewport', 'positionGridViewport', 'waitForFileViewport',
    'captureContinuation', 'restoreContinuationAnchor'].map(method).join('\n') + '}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exportsObject, FileGridLayout: layoutExports.FileGridLayout,
  ContinuationSnapshot: class { constructor() { this.state = { scene: 'directory' }; this.entries = []; } },
  IMAGE_RETURN_MOUNT_FRAME_LIMIT: 8, EXPERIMENT_GRID_CACHED_COUNT: 4,
  ScrollAlign: { START: 0 }, LengthMetrics: { vp: n => n }, console });

function make() {
  const h = new exportsObject.H(), frames = [], jumps = [];
  let width = 960, height = 1440, offset = 0, geometryReads = 0;
  const entries = Array.from({ length: 2000 }, (_, i) => ({ path: '/album/' + i + (i % 5 ? '.jpg' : '.mp4') }));
  Object.assign(h, { pageWidthVp: width, pageHeightVp: height, fileViewportVersion: 0,
    gridViewportAnchor: null, gridViewportRestore: null, waterfallAnchorRestoreToken: 0, navigationRequestId: 4,
    currentPath: '/album', currentRootType: 4, fileSortKey: 'time', fileSortAscending: false,
    linkId: 'nas', rootKind: 'personal', repository: { sessionIdentity: () => 'nas|user' },
    fileVisibleStartIndex: 205, fileVisibleEndIndex: 245, imageVisualStates: {},
    screen: 'files', fileViewMode: 'grid', showSearch: false, entries,
    viewerBlocksFileContent: false, showImageViewer: false, viewerClosePending: false,
    fileContentTouchActive: false, fileTransitionHeader: null,
    fileScrollViewport: { y: 0 }, fileContentTopInset: () => 100,
    audioPlaybackUiVisible: () => false, videoPlaybackUiVisible: () => false,
    fileGridColumnCount: () => layoutExports.FileGridLayout.columns(h.pageWidthVp, h.pageHeightVp),
    getUIContext: () => ({ px2vp: n => n / 2, getComponentUtils: () => ({ getRectangleById: () => {
      geometryReads++; return { size: { width: width * 2, height: height * 2 } };
    } }) }), nextRenderFrame: () => new Promise(resolve => frames.push(resolve)) });
  const columns = () => h.fileGridColumnCount();
  const rowHeight = () => (width - (columns() - 1)) / columns();
  h.fileListScroller = {
    currentOffset: () => ({ xOffset: 0, yOffset: offset }),
    getItemIndex: (_x, y) => Math.max(0, Math.floor((offset + y - 100) / (rowHeight() + 1))) * columns(),
    getItemRect: index => ({ x: (index % columns()) * (rowHeight() + 1),
      y: 100 + Math.floor(index / columns()) * (rowHeight() + 1) - offset, width: rowHeight(), height: rowHeight() }),
    scrollToIndex(index, smooth, align, options) {
      assert.equal(smooth, false); assert.equal(align, 0);
      const row = Math.floor(index / columns());
      offset = 100 + row * (rowHeight() + 1) + options.extraOffset;
      jumps.push({ index, row, offset, columns: columns() });
      // Native scroll callbacks also run for our own indexed restoration.
      h.rememberGridViewportAnchor();
    },
    scrollTo(options) { offset = options.yOffset; jumps.push({ index: 0, row: 0, offset, columns: columns() }); }
  };
  const scroll = (index, clipped = 20) => {
    h.gridViewportRestore = null; // TouchDown cancels any outstanding correction.
    offset = Math.floor(index / columns()) * (rowHeight() + 1) + clipped;
    h.rememberGridViewportAnchor();
  };
  const nativeSize = (w, v) => { width = w; height = v; };
  const resize = (w, v) => { nativeSize(w, v); h.recordFilePageSize({ width: w, height: v }); };
  const flush = async () => { for (let i = 0; i < 12; i++) {
    const next = frames.splice(0); next.forEach(fn => fn()); await Promise.resolve();
  } };
  scroll(205);
  return { h, entries, frames, jumps, scroll, resize, nativeSize, flush, offset: () => offset, reads: () => geometryReads };
}
(async () => {
  let t = make(), original = t.h.gridViewportAnchor, originalOffset = t.offset();
  assert.equal(original.path, '/album/205.mp4', 'anchor the leading file, including a video in a mixed photo folder');
  assert.ok(original.clippedFraction > 0, 'remember the partially clipped row below the header');

  // Native layout and scroll-index change BEFORE parent onAreaChange. Never capture this row.
  t.nativeSize(1440, 960); t.h.rememberGridViewportAnchor();
  assert.equal(t.h.gridViewportAnchor, original);
  t.h.recordFilePageSize({ width: 1440, height: 960 });
  assert.equal(t.jumps.length, 1, 'position in the same size transaction'); await t.flush();
  assert.equal(t.jumps.length, 1); assert.equal(t.jumps[0].row, Math.floor(205 / 7));
  assert.equal(t.jumps[0].index, 205, 'native grid positioning always addresses the original file, never a row adapter');
  assert.equal(t.h.gridViewportAnchor, original, 'the containing row starts at 203, but the anchor must remain 205');
  const rowY = t.h.fileListScroller.getItemRect(205).y;
  assert.ok(rowY < 100 && rowY > 0, 'extraOffset preserves the clipped row with the correct sign');

  // Window notification is synchronous and can precede native component layout.
  const early = make(), earlyAnchor = early.h.gridViewportAnchor;
  early.h.updateFilePageSize(1440, 960);
  assert.equal(early.h.fileGridColumnCount(), 7); assert.equal(early.jumps.length, 1);
  early.nativeSize(1440, 960); early.h.recordFilePageSize({ width: 1440, height: 960 });
  await early.flush();
  assert.equal(early.h.gridViewportAnchor, earlyAnchor);
  assert.equal(early.h.fileViewportVersion, 1, 'matching area callback must not regroup a second time');
  assert.ok(early.jumps.length <= 2, 'only a bounded post-layout correction may follow the synchronous jump');
  assert.ok(Math.abs(early.h.fileListScroller.getItemRect(205).y -
    (100 - earlyAnchor.clippedFraction * early.h.fileListScroller.getItemRect(205).height)) < .01);

  // Intermediate sizes last longer than the layout wait. The old implementation
  // retired the original anchor and compounded the rounding on each rotation.
  for (let i = 0; i < 5; i++) {
    for (const [w, h] of [[1100, 1100], [960, 1440], [1440, 960]]) {
      t.resize(w, h); await t.flush();
      assert.equal(t.h.gridViewportAnchor, original);
      assert.equal(t.jumps.at(-1).row, Math.floor(205 / t.h.fileGridColumnCount()));
    }
  }
  t.resize(960, 1440); await t.flush();
  assert.ok(Math.abs(t.offset() - originalOffset) < 0.01, 'repeated rotation must not drift through the album');
  const calls = t.jumps.length, reads = t.reads();
  t.h.rememberGridViewportAnchor(); await t.flush();
  assert.equal(t.jumps.length, calls); assert.equal(t.reads(), reads, 'our correction cannot feed back into another snapshot');

  // A real new scroll becomes the anchor; pending work must never pull it back.
  t.resize(1440, 960); const applied = t.jumps.length; t.scroll(483, 0); await t.flush();
  assert.equal(t.jumps.length, applied);
  assert.equal(t.h.gridViewportAnchor.path, '/album/483.jpg');
  t.resize(960, 1440); await t.flush(); assert.equal(t.jumps.at(-1).row, Math.floor(483 / 5));

  t = make(); t.scroll(0, 0); t.resize(1440, 960); await t.flush();
  assert.equal(t.offset(), 0, 'the folder start keeps its header inset');
  t = make(); t.h.entries = t.entries.slice(0, 200).concat(t.entries.slice(201));
  t.resize(1440, 960); await t.flush(); assert.equal(t.jumps[0].row, Math.floor(204 / 7), 'identity survives removal before the anchor');
  t = make(); t.h.entries = []; t.resize(1440, 960); await t.flush(); assert.equal(t.jumps.length, 0);

  for (const cancel of [h => { h.gridViewportRestore = null; }, h => { h.navigationRequestId++; },
    h => { h.currentPath = '/other'; }, h => { h.currentRootType = 3; }, h => { h.fileSortKey = 'name'; },
    h => { h.fileSortAscending = true; }, h => { h.waterfallAnchorRestoreToken++; },
    h => { h.showSearch = true; }, h => { h.showImageViewer = true; }, h => { h.fileViewMode = 'waterfall'; }]) {
    t = make(); t.resize(1440, 960); const initial = t.jumps.length; cancel(t.h); await t.flush();
    assert.equal(t.jumps.length, initial, 'input or a superseded context cannot receive a delayed jump');
  }
  for (const block of [h => { h.showImageViewer = true; }, h => { h.showSearch = true; },
    h => { h.fileContentTouchActive = true; }, h => { h.fileViewMode = 'list'; },
    h => { h.viewerBlocksFileContent = true; }, h => { h.fileTransitionHeader = {}; },
    h => { h.audioPlaybackUiVisible = () => true; }, h => { h.videoPlaybackUiVisible = () => true; },
    h => { h.gridViewportAnchor = null; }]) {
    t = make(); block(t.h); t.resize(1440, 960); await t.flush();
    assert.equal(t.jumps.length, 0); assert.equal(t.h.fileGridColumnCount(), 7);
  }
  t = make(); const untouched = t.h.gridViewportAnchor;
  t.resize(960, 1440); await t.flush(); assert.equal(t.jumps.length, 0); assert.equal(t.h.gridViewportAnchor, untouched);
  t = make(); let unstableFrames = 0;
  t.h.nextRenderFrame = async () => { unstableFrames++; t.h.fileViewportVersion++; };
  t.resize(1440, 960); await new Promise(setImmediate);
  assert.ok(unstableFrames > 0 && unstableFrames <= 8); assert.equal(t.jumps.length, 1, 'no unbounded resize polling or additional jumps into an unstable layout');

  // Real page adapters use exactly the same file + normalized row position
  // for continuation. Neither a source pixel offset nor its column count crosses devices.
  t = make(); const sent = t.h.captureContinuation();
  assert.equal(sent.state.anchor, '/album/205.mp4');
  assert.equal(sent.state.anchorFraction, t.h.gridViewportAnchor.clippedFraction);
  assert.equal(sent.state.anchorAtStart, false);
  const receiver = make(); receiver.nativeSize(1440, 960);
  Object.assign(receiver.h, { pageWidthVp: 1440, pageHeightVp: 960, gridViewportAnchor: null });
  receiver.h.fileContentTopInset = () => 120;
  const work = receiver.h.restoreContinuationAnchor(JSON.parse(JSON.stringify(sent.state)), () => true);
  await receiver.flush(); await work;
  assert.equal(receiver.jumps[0].row, Math.floor(205 / 7));
  assert.equal(receiver.h.gridViewportAnchor.path, sent.state.anchor);
  const newHeight = receiver.h.fileListScroller.getItemRect(205).height;
  assert.ok(Math.abs(receiver.h.fileListScroller.getItemRect(205).y - (120 - sent.state.anchorFraction * newHeight)) < .01);
  receiver.resize(960, 1440); await receiver.flush();
  assert.equal(receiver.jumps.at(-1).row, 41, 'rotation after receiving keeps the transferred file');
  for (const [width, height, columns] of [[374, 827, 4], [800, 800, 6]]) {
    const peer = make(); peer.nativeSize(width, height);
    Object.assign(peer.h, { pageWidthVp: width, pageHeightVp: height });
    const restore = peer.h.restoreContinuationAnchor(sent.state, () => true); await peer.flush(); await restore;
    assert.equal(peer.jumps[0].row, Math.floor(205 / columns), 'phone/foldable peers use their own columns');
  }
  t = make(); const olderState = { anchor: '/album/450.mp4' };
  const legacyWork = t.h.restoreContinuationAnchor(olderState, () => true); await t.flush(); await legacyWork;
  assert.equal(t.jumps[0].row, 90, 'old senders still restore their file identity');
  assert.equal(t.h.fileListScroller.getItemRect(450).y, 100);
  t = make(); let valid = true;
  const cancelled = t.h.restoreContinuationAnchor(sent.state, () => valid); valid = false;
  await t.flush(); await cancelled; assert.equal(t.jumps.length, 0);

  assert.match(source, /updateTimelineFocusFromVisible\(first, 'grid'\)\s+this.rememberGridViewportAnchor\(\)/);
  for (const name of ['onFileContentScrollStop', 'finishPreparedFileTransition', 'completeBackFileTransition', 'finishCloseImageViewer']) {
    assert.match(method(name), /rememberGridViewportAnchor/);
  }
  assert.doesNotMatch(method('recordFilePageSize'), /captureFileViewAnchor/);
  console.log('PASS: grid anchor — pre-reflow snapshot, mixed files, repeated rotations without drift, cancellation, clipped-row alignment and cross-viewport continuation/old-peer compatibility');
})().catch(error => { console.error(error); process.exitCode = 1; });

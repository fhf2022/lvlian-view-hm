// node tests/mixed-directory-view-regression.cjs <SDK typescript.js>
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
function compile(source) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports });
  return exports;
}
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const names = ['syncDirectoryMediaEntries', 'sameWaterfallEntry', 'preferredViewMode', 'defaultViewMode',
  'applyPreferredViewMode', 'prepareWaterfallPipeline', 'selectionEntries', 'allEntriesSelected',
  'toggleSelectAll', 'selectedEntriesInCurrentDirectory', 'setSelectedPaths', 'publishFileSelection',
  'isSelected', 'isImage', 'isVideo', 'isAudio', 'fileExtension'];
const { Page } = compile('export class Page {\n' + names.map(method).join('\n') + '\n}');
let serial = 0;
function entry(ext, size = 2 * 1024 * 1024, directory = false) {
  const name = `${serial++}.${ext}`;
  return { name, path: '/mixed/' + name, size, isDirectory: directory, mimeType: '' };
}
const photos = (n, size) => Array.from({ length: n }, () => entry('jpg', size));
function make(entries) {
  const h = new Page(), selected = new Set();
  Object.assign(h, { entries, waterfallEntries: [], waterfallBatches: null, fileViewMode: 'list',
    screen: 'files', showSearch: false, currentRootType: 3, currentPath: '/mixed',
    defaultPhotoViewMode: 'grid', defaultFileViewMode: 'list', defaultAudioViewMode: 'list',
    directoryViewModeOverrides: {}, selectedPaths: [], selectedEntryCount: 0, selectedEntriesCache: null,
    frames: [], stops: 0, starts: 0,
    isRootListing: () => false, resetWaterfallDirectoryState() {}, endDragSelection() {},
    stopWaterfallPipeline() { this.stops++; }, ensureWaterfallStarted() { this.starts++; },
    postRenderFrame(fn) { this.frames.push(fn); }, syncGestureShareRegistration() {},
    fileSelection: { has: p => selected.has(p), count: () => selected.size, paths: () => Array.from(selected),
      replace(paths) { selected.clear(); paths.forEach(p => selected.add(p)); } }
  });
  h.syncDirectoryMediaEntries(entries, false);
  return h;
}
for (const [entries, album, available, kind] of [
  [[], false, false, 'file'],
  [[entry('jpg', 100)], true, true, 'photo'],
  [[entry('mp4')], true, false, 'photo'],
  [[entry('mp3')], false, false, 'audio'],
  [[entry('jpg', 0), entry('txt')], false, true, 'file'],
  [[entry('jpg', 999, true), entry('txt')], false, false, 'file'],
  [[...photos(5), entry('txt')], false, true, 'file'],
  [[...photos(6, 1024 * 1024), entry('txt')], false, true, 'file'],
  [[...photos(6, 1024 * 1024 + 1), ...photos(4, 10), entry('zip'), entry('folder', 0, true)], true, true, 'photo']
]) {
  const h = make(entries);
  assert.equal(h.currentDirectoryIsPhotoAlbum, album);
  assert.equal(h.currentDirectoryHasImages, available);
  h.defaultAudioViewMode = 'audio'; h.defaultFileViewMode = 'file'; h.defaultPhotoViewMode = 'photo';
  assert.equal(h.preferredViewMode(), kind);
  assert.equal(h.entries, entries, 'the complete directory is retained for file operations, search and navigation');
  assert.ok(h.waterfallEntries.every(e => !e.isDirectory && h.isImage(e)));
}

// Discovery in a later page unlocks the view without moving the user's current
// surface. Likewise a later non-image page must not kick an image flow out.
const h = make([entry('txt')]);
h.entries = [...h.entries, ...photos(6), entry('folder', 0, true)];
h.syncDirectoryMediaEntries(h.entries, true);
assert.equal(h.currentDirectoryHasImages, true);
assert.equal(h.fileViewMode, 'list');
assert.equal(h.starts, 0);
h.applyPreferredViewMode(); assert.equal(h.fileViewMode, 'grid');
h.directoryViewModeOverrides['3:/mixed'] = 'waterfall';
h.applyPreferredViewMode(); assert.equal(h.fileViewMode, 'waterfall');
const firstImage = h.waterfallEntries[0];
h.entries.push(entry('pdf'));
h.syncDirectoryMediaEntries(h.entries, true);
assert.equal(h.fileViewMode, 'waterfall');
assert.equal(h.waterfallEntries[0], firstImage, 'filtering keeps file identities and order');

// All selection and action inputs must use the image catalog in waterfall,
// including images outside the resident batch. Hidden documents cannot leak.
h.fileViewMode = 'grid'; h.setSelectedPaths(h.entries.map(e => e.path));
h.prepareWaterfallPipeline(); h.fileViewMode = 'waterfall';
assert.equal(h.selectedEntryCount, 6);
assert.equal(h.selectedEntriesInCurrentDirectory().length, 6);
assert.equal(h.allEntriesSelected(), true);
h.toggleSelectAll(); assert.equal(h.selectedEntryCount, 0);
h.toggleSelectAll(); assert.equal(h.selectedEntryCount, 6);
assert.ok(h.selectedEntriesInCurrentDirectory().every(e => h.isImage(e)));
h.fileViewMode = 'grid'; h.selectedEntriesCache = null;
assert.equal(h.allEntriesSelected(), false);
h.toggleSelectAll(); assert.equal(h.selectedEntryCount, h.entries.length);

// Losing the final image safely reveals the remaining files. A recorded or
// configured waterfall default cannot strand an empty/video-only directory.
h.entries = h.entries.filter(e => !h.isImage(e)); h.fileViewMode = 'waterfall';
h.syncDirectoryMediaEntries(h.entries, false);
assert.equal(h.currentDirectoryHasImages, false);
assert.equal(h.fileViewMode, 'grid');
h.applyPreferredViewMode(); assert.equal(h.fileViewMode, 'grid');
const videos = make([entry('mp4')]); videos.defaultPhotoViewMode = 'waterfall';
videos.applyPreferredViewMode(); assert.equal(videos.fileViewMode, 'grid');

// Large-directory guard: qualifying size reads stop at six, while the one
// existing catalog pass still includes every image, including small ones.
let sizeReads = 0;
const many = photos(20000);
for (const e of many) Object.defineProperty(e, 'size', { get() { sizeReads++; return 2 * 1024 * 1024; } });
const big = make([...many, entry('txt')]);
assert.equal(sizeReads, 6);
assert.equal(big.waterfallEntries.length, 20000);
assert.equal(big.currentDirectoryIsPhotoAlbum, true);
console.log('PASS mixed directory: defaults/size threshold, pagination stability, image-only selection, last-image fallback, bounded size checks');

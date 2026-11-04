const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2]);
function compile(source, bindings = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports, ...bindings });
  return exports;
}
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const { MediaType } = compile(fs.readFileSync('entry/src/main/ets/model/MediaType.ets', 'utf8'));
function method(name) {
  const a = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(a >= 0, name);
  const b = source.slice(a + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(a, a + b + 1);
}
let serial = 0;
class TransferBatch {
  constructor(title, scope) { this.title = title; this.ownerScope = scope; this.batchId = 'batch-' + (++serial); }
}
const names = ['openEntry', 'openSearchResult', 'openMediaEntry', 'quickView',
  'isImage', 'isVideo', 'isAudio', 'enqueueDownloadFile', 'downloadEntry',
  'downloadEntryFromMenu', 'downloadFileFromAction', 'downloadVideoFromPlayer',
  'downloadSelectedEntries', 'enqueueRemoteTree'];
const { Page } = compile('export class Page {\n' + names.map(method).join('\n') + '\n}', {
  MediaType, TransferBatch, DownloadDestination: { directory: async () => '/downloads' }
});
function entry(name, isDirectory = false, mimeType = '') { return { name, path: '/temp/' + name, mimeType, isDirectory, rootType: 3 }; }
function make() {
  const p = new Page(), events = [];
  let scope = 'one';
  Object.assign(p, { isBusy: false, searchResults: [],
    repository: { cacheScopeHash: () => scope, list: async () => [] },
    tapTraceBegin() {}, traceInteractionGuards() {},
    deferOpenEntry(e) { events.push(['defer', e]); }, dismissKeyboard() { events.push(['keyboard']); },
    prepareSearchReturn(kind) { events.push(['return', kind]); },
    openImageViewer: async (e, images) => { events.push(['image', e, images]); },
    openAudioPlayer: async e => { events.push(['audio', e]); },
    openVideoPlayer: async e => { events.push(['video', e]); },
    openSearchResultFolder: async e => { events.push(['folder', e]); },
    openCachedEntry: async (e, picker) => { events.push(['cache', e, picker]); },
    ensureDownloadState: async () => { events.push(['init']); },
    refreshVideoManager: async () => { events.push(['video-init']); },
    downloadQueue: { enqueue: async (...args) => { events.push(['download', ...args]); } },
    videoTransferManager: { requestDownload: async (...args) => { events.push(['video-download', ...args]); } },
    closeActionMenu() { events.push(['close-menu']); },
    confirmMeteredDownload: async () => true,
    showImmersiveToast(text) { events.push(['toast', text]); },
    reportError(error, title) { events.push(['error', title, error.message]); },
    selectedEntriesInCurrentDirectory: () => [], closeSelectionMoreMenu() {},
    exitSelectionMode() { events.push(['selection-exit']); },
    finishDownloadBatch: async (batch, complete) => { events.push(['batch-finish', batch, complete]); },
    ensureLocalDirectory(path) { events.push(['mkdir', path]); }, safeLocalPath: path => path
  });
  return { p, events, changeScope: () => { scope = 'two'; } };
}
(async () => {
  for (const [name, kind] of [['a.jpg', 'image'], ['a.mp3', 'audio'], ['a.mpg', 'video']]) {
    for (const route of ['openEntry', 'openSearchResult', 'quickView']) {
      const { p, events } = make(), e = entry(name);
      p.searchResults = [entry('other.jpg'), entry('folder.jpg', true), entry('song.mp3'), e];
      await p[route](e);
      assert.equal(events.filter(x => x[0] === kind).length, 1, route + ' opens exactly one correct player');
      assert.equal(events.some(x => x[0] === 'download' || x[0] === 'video-download' || x[0] === 'cache'), false);
      if (route === 'openSearchResult') {
        const prepared = events.findIndex(x => x[0] === 'return');
        assert.ok(prepared >= 0 && prepared < events.findIndex(x => x[0] === kind));
        assert.equal(events[prepared][1], kind);
        if (kind === 'image') {
          const images = events.find(x => x[0] === 'image')[2];
          assert.deepEqual(Array.from(images, x => x.name), ['other.jpg', 'a.jpg']);
        }
      } else {
        assert.equal(events.some(x => x[0] === 'return'), false);
        if (kind === 'image') assert.equal(events.find(x => x[0] === 'image')[2], undefined);
      }
    }
  }
  let h = make(), ordinary = entry('a.txt');
  await h.p.openEntry(ordinary); assert.equal(h.events.filter(x => x[0] === 'download').length, 1);
  h = make(); await h.p.openSearchResult(ordinary); assert.equal(h.events.filter(x => x[0] === 'download').length, 1);
  assert.equal(h.events.some(x => x[0] === 'return'), false, 'ordinary search download does not enter a media-return session');
  h = make(); await h.p.quickView(ordinary); assert.equal(h.events.find(x => x[0] === 'cache')[2], false);
  assert.equal(h.events.some(x => x[0] === 'download'), false, 'quick view keeps local-cache fallback');
  h = make(); h.p.isBusy = true; await h.p.openEntry(entry('a.jpg')); assert.equal(h.events[0][0], 'defer');
  h = make(); h.p.isBusy = true; await h.p.openSearchResult(entry('a.jpg')); assert.equal(h.events.length, 0);
  h = make(); await h.p.openSearchResult(entry('folder', true)); assert.equal(h.events.at(-1)[0], 'folder');
  h = make(); h.p.openAudioPlayer = async () => { throw Error('player failed'); };
  await assert.rejects(h.p.openSearchResult(entry('a.mp3')), /player failed/);
  assert.equal(h.events.some(x => x[0] === 'download'), false, 'media failure is not mistaken for an ordinary file');

  // All explicit downloads use the same queue dispatcher and retain batch/path metadata.
  h = make(); const video = entry('movie.mp4'), batch = new TransferBatch('Folder', 'one');
  await h.p.enqueueDownloadFile(ordinary, '/downloads', 'Folder/a.txt', batch);
  await h.p.enqueueDownloadFile(video, '/downloads', 'Folder/movie.mp4', batch);
  assert.equal(h.events[0][0], 'download'); assert.equal(h.events[1][0], 'video-download');
  for (const event of h.events) { assert.equal(event[2], '/downloads'); assert.equal(event[4], batch); }
  await assert.rejects(h.p.enqueueDownloadFile(entry('Folder', true)), /文件夹/);
  h.changeScope(); await assert.rejects(h.p.enqueueDownloadFile(video, '', '', batch), /账号已变化/);
  assert.equal(h.events.length, 2);
  h = make(); await h.p.downloadEntry(video);
  assert.ok(h.events.findIndex(x => x[0] === 'video-init') < h.events.findIndex(x => x[0] === 'video-download'));
  assert.equal(h.events.some(x => x[0] === 'download'), false);
  h = make(); h.p.confirmMeteredDownload = async () => false;
  await h.p.downloadFileFromAction(video); assert.deepEqual(h.events.map(x => x[0]), ['close-menu']);
  h = make(); await h.p.downloadFileFromAction(ordinary); assert.equal(h.events.filter(x => x[0] === 'download').length, 1);
  h = make(); await h.p.downloadFileFromAction(video); assert.equal(h.events.filter(x => x[0] === 'video-download').length, 1); assert.equal(h.p.isBusy, false);

  h = make(); const folder = entry('Folder', true);
  h.p.repository.list = async () => [ordinary, video];
  const count = await h.p.enqueueRemoteTree(folder, '/downloads', 'Folder', batch);
  assert.equal(count, 2); assert.equal(h.events.filter(x => x[0] === 'download').length, 1);
  assert.equal(h.events.filter(x => x[0] === 'video-download').length, 1);
  assert.equal(h.events.find(x => x[0] === 'video-download')[3], 'Folder/movie.mp4');

  h = make(); h.p.selectedEntriesInCurrentDirectory = () => [ordinary, video, entry('other.mp4')];
  await h.p.downloadSelectedEntries();
  assert.equal(h.events.filter(x => x[0] === 'video-init').length, 1, 'selection prepares video service once, not once per file');
  const queued = h.events.filter(x => x[0] === 'download' || x[0] === 'video-download');
  assert.equal(queued.length, 3); assert.ok(queued[0][4]);
  assert.ok(queued.every(x => x[4] === queued[0][4]), 'ordinary/video files share the same batch');
  assert.equal(h.events.find(x => x[0] === 'batch-finish')[2], true); assert.equal(h.p.isBusy, false);
  h = make(); h.p.selectedEntriesInCurrentDirectory = () => [ordinary, video];
  h.p.videoTransferManager.requestDownload = async () => { throw Error('denied'); };
  await h.p.downloadSelectedEntries(); assert.equal(h.events.find(x => x[0] === 'batch-finish')[2], false);
  assert.equal(h.events.some(x => x[0] === 'selection-exit'), false); assert.equal(h.p.isBusy, false);
  h = make(); h.p.downloadQueue.enqueue = async () => { throw Error('denied'); };
  await h.p.downloadFileFromAction(ordinary); assert.equal(h.events.filter(x => x[0] === 'error').length, 1);
  assert.equal(h.events.some(x => x[0] === 'toast'), false);
  assert.equal((source.match(/this\.downloadQueue\.enqueue\(entry/g) || []).length, 1);
  assert.equal((source.match(/this\.videoTransferManager\.requestDownload\(entry/g) || []).length, 1);
  console.log('PASS B2/B3 shared dispatch: all three open contexts and fallbacks, search catalog/return ordering, busy/folder/error guards; ordinary/video download routing, cache promotion path, metered cancel, tree paths, shared batches, once-per-selection initialization, partial admission failure and account guard');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Host regression. Native distributed transport is mocked, not a two-device certification.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require(process.argv[2]);
const root = process.cwd();
const fixtureDir = path.join(root, 'temp/continuation/files');
fs.mkdirSync(fixtureDir, {recursive: true});
const storage = new Map();
const AppStorage = {setOrCreate: (k, v) => storage.set(k, v), get: k => storage.get(k)};
const logs = [];
const modules = new Map();
const sessions = new Map();
let rejectSave = false;
let delaySave = null;
let rejectJoin = false;
let delayJoin = null;
let shortWrites = false;
const nativeObjects = [];
const cleanupManagers = [];
class FakeDataObject {
  constructor(data) { Object.assign(this, data); this.observer = null; nativeObjects.push(this); }
  on(type, fn) { assert.equal(type, 'status'); this.observer = fn; }
  off(type, fn) { assert.equal(fn, this.observer); this.observer = null; }
  async setSessionId(id) {
    if (!id) { this.session = ''; return; }
    if (delayJoin) { await delayJoin; }
    if (rejectJoin) { throw new Error('native join failed'); }
    this.session = id;
    const previous = sessions.get(id);
    if (previous && previous !== this) {
      this.snapshot = previous.snapshot;
      // Deliberately emit before the join promise resolves.
      assert.ok(this.observer, 'must subscribe before joining');
      this.observer(id, 'source-device', 'restored');
    } else { sessions.set(id, this); }
  }
  async save(device) {
    assert.ok(this.session); assert.equal(device, 'target-device');
    this.saveStarted = true;
    if (delaySave) { await delaySave; }
    if (rejectSave) { throw new Error('native save failed'); }
    return {sessionId: this.session, deviceId: device, version: 1};
  }
  async revokeSave() { sessions.delete(this.session); }
}
const positions = new Map();
const io = {
  OpenMode: {CREATE: 1, READ_WRITE: 2, TRUNC: 4, READ_ONLY: 8},
  open: async (p, mode) => {
    const fd = fs.openSync(p, mode & 1 ? 'w+' : 'r'); positions.set(fd, 0); return {fd};
  },
  write: async (fd, buffer) => {
    const count = fs.writeSync(fd, Buffer.from(buffer), 0, shortWrites ? Math.min(79, buffer.byteLength) : buffer.byteLength);
    return count;
  },
  read: async (fd, buffer) => {
    const count = fs.readSync(fd, Buffer.from(buffer), 0, Math.min(12001, buffer.byteLength), null);
    return count;
  },
  close: async file => { positions.delete(file.fd); fs.closeSync(file.fd); },
  unlink: async p => fs.unlinkSync(p),
  listFile: async p => fs.readdirSync(p),
  stat: async p => {
    const s = fs.statSync(p);
    return {size: s.size, ctime: s.ctimeMs / 1000, mtime: s.mtimeMs / 1000, isFile: () => s.isFile()};
  }
};
const native = {
  '@kit.AbilityKit': {
    AbilityConstant: {ContinueState: {ACTIVE: 1, INACTIVE: 0}, OnContinueResult: {AGREE: 0, REJECT: 1, MISMATCH: 2}},
    wantConstant: {Params: {SUPPORT_CONTINUE_SOURCE_EXIT_KEY: 'sourceExit', SUPPORT_CONTINUE_PAGE_STACK_KEY: 'pageStack'}}
  },
  '@kit.CoreFileKit': {fileIo: io, fileUri: {getUriFromPath: p => 'file://' + p}},
  '@kit.ArkData': {distributedDataObject: {create: (_c, data) => new FakeDataObject(data), genSessionId: () => crypto.randomBytes(16).toString('hex')}},
  '@kit.PerformanceAnalysisKit': {hilog: {info: (...args) => logs.push(args), warn: (...args) => logs.push(args)}},
  '@kit.ArkTS': {util: {
    generateRandomUUID: () => crypto.randomUUID(),
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: {create: (encoding, options) => {
      const decoder = new TextDecoder(encoding, options);
      return {decodeToString: (bytes, options) => decoder.decode(bytes, options)};
    }}
  }}
};
function load(file) {
  file = path.resolve(file);
  if (modules.has(file)) return modules.get(file);
  const exports = {};
  modules.set(file, exports);
  const source = fs.readFileSync(file, 'utf8');
  const compiled = ts.transpileModule(source, {compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true
  }}).outputText;
  vm.runInNewContext(compiled, {exports, require: key => {
    if (native[key]) return native[key];
    return load(path.resolve(path.dirname(file), key + '.ets'));
  }, Observed: value => value, AppStorage, setTimeout, clearTimeout, Date, Math, Number, JSON, Map, Set,
  Promise, ArrayBuffer, Uint8Array, Error, Object, console}, {filename: file});
  return exports;
}
const {FileEntry} = load('entry/src/main/ets/model/FileEntry.ets');
const {ContinuationSnapshot, ContinuationPolicy: policy} = load('entry/src/main/ets/continuation/ContinuationModel.ets');
const {ContinuationSnapshotStore: store} = load('entry/src/main/ets/continuation/ContinuationSnapshotStore.ets');
const {ContinuationManager, ContinuationAccountRequired} = load('entry/src/main/ets/continuation/ContinuationManager.ets');
const {DirectoryTimelinePolicy, DirectoryQuery} = load('entry/src/main/ets/model/DirectoryTimeline.ets');
const context = {distributedFilesDir: fixtureDir, setMissionContinueState: async value => logs.push(value)};
const turn = () => new Promise(resolve => setTimeout(resolve, 5));
async function until(predicate) {
  for (let i = 0; i < 400; i++) { if (predicate()) return; await turn(); }
  throw new Error('timed out waiting for regression result');
}
function entry(p, dir = false) {
  const e = new FileEntry();
  e.path = p; e.name = p.split('/').pop(); e.isDirectory = dir; e.rootType = 3;
  e.modifiedTime = 1720000000; e.createdTime = 1710000000; e.size = 12;
  e.thumbnailUrl = 'https://private/token=DO_NOT_TRANSFER'; e.coverUrl = 'file:///private/cache';
  return e;
}
function snapshot(count = 3) {
  const s = new ContinuationSnapshot();
  Object.assign(s.state, {requestId: crypto.randomUUID(), createdAt: Date.now(), nasId: 'my-nas', userId: 'uid-1',
    path: '/home/test/Photos', rootType: 3, count});
  s.entries = Array.from({length: count}, (_, i) => entry(s.state.path + '/图片-' + i + '-📷.jpg'));
  if (count) s.state.anchor = s.entries[count - 1].path;
  return s;
}

async function run() {
  let cases = 0;
  const s = snapshot();
  policy.validate(s.state);
  assert.ok(policy.sameAccount(s.state, ' MY-NAS ', 'https://relay|uid-1'));
  assert.ok(!policy.sameAccount(s.state, 'my-nas', 'https://relay|uid-2'));
  assert.ok(!policy.sameAccount(s.state, 'other-nas', 'https://relay|uid-1'));
  assert.ok(!policy.sameAccount(s.state, 'my-nas', ''));
  for (const bad of ['/home/../secret', '/home//photo', '/home/./photo', '/home/#recycle/photo', '/home/abc\\def', 'relative', '/home/']) {
    assert.ok(!policy.path(bad), bad);
  }
  for (const mutation of [
    x => x.protocol = 3, x => x.createdAt -= policy.MAX_AGE_MS + 1,
    x => x.count = policy.MAX_ENTRIES + 1, x => x.anchor = '/home/elsewhere/a.jpg',
    x => {x.scene = 'video'; x.target = '/outside/video.mp4';}, x => x.playing = 'yes',
    x => {x.anchorFraction = NaN; x.anchorAtStart = false;}, x => {x.anchorFraction = 1; x.anchorAtStart = false;},
    x => {x.anchorFraction = -0.1; x.anchorAtStart = false;}, x => {x.anchorFraction = 0.2;},
    x => {x.anchorAtStart = false;}, x => {x.anchorFraction = 0.3; x.anchorAtStart = 'false';}
  ]) {
    const altered = JSON.parse(JSON.stringify(s.state)); mutation(altered);
    assert.throws(() => policy.validate(altered));
  }
  const row = policy.encode(s.entries[0]);
  assert.ok(!row.includes('DO_NOT_TRANSFER') && !row.includes('file:///'));
  assert.equal(policy.decode(row, s.state).path, s.entries[0].path);
  assert.equal(policy.decode(row, s.state).thumbnailUrl, '');
  assert.throws(() => policy.decode(row.replace(s.entries[0].path, '/outside/evil.jpg'), s.state));
  const roots = [entry('/home/test', true), entry('/shares/pictures', true)];
  assert.deepEqual(Array.from(policy.ancestors('/home/test/Photos/2026', roots)), ['', '/home/test', '/home/test/Photos']);
  assert.throws(() => policy.ancestors('/home/test-other/Photos', roots));
  assert.throws(() => policy.ancestors('/secret/Photos', roots));
  cases++;

  s.state.view = 'grid'; s.state.anchorFraction = 0.35; s.state.anchorAtStart = false;
  policy.validate(s.state);
  shortWrites = true;
  const asset = await store.write(context, s, () => true);
  shortWrites = false;
  const roundTrip = await store.read(context, s.state.requestId, asset, () => true);
  assert.equal(roundTrip.entries.length, 3);
  assert.equal(roundTrip.entries[2].path, s.entries[2].path);
  assert.equal(roundTrip.state.anchorFraction, 0.35); assert.equal(roundTrip.state.anchorAtStart, false);
  assert.equal(positions.size, 0);
  await assert.rejects(store.read(context, s.state.requestId, {...asset, name: '../../secret'}, () => true));
  await assert.rejects(store.read(context, s.state.requestId, {...asset, size: '1'}, () => true));
  await assert.rejects(store.read(context, s.state.requestId, asset, () => false));
  await store.remove(asset.path);
  const empty = snapshot(0);
  const emptyAsset = await store.write(context, empty, () => true);
  assert.equal((await store.read(context, empty.state.requestId, emptyAsset, () => true)).entries.length, 0);
  await store.remove(emptyAsset.path);
  const rootSnapshot = snapshot(0);
  rootSnapshot.state.path = ''; rootSnapshot.state.count = 1;
  rootSnapshot.entries = [entry('/home/test', true)]; rootSnapshot.entries[0].name = '个人空间';
  rootSnapshot.state.anchor = '/home/test';
  const rootAsset = await store.write(context, rootSnapshot, () => true);
  assert.equal((await store.read(context, rootSnapshot.state.requestId, rootAsset, () => true)).entries[0].name, '个人空间');
  await store.remove(rootAsset.path);
  cases++;

  const large = snapshot(50000);
  const begin = Date.now();
  const largeAsset = await store.write(context, large, () => true);
  const largeRead = await store.read(context, large.state.requestId, largeAsset, () => true);
  assert.equal(largeRead.entries.length, 50000);
  assert.equal(largeRead.entries[49999].path, large.entries[49999].path);
  assert.ok(Number(largeAsset.size) < policy.MAX_BYTES);
  console.log(`50,000 entries: ${largeAsset.size} bytes, chunked encode/read ${Date.now() - begin} ms (host only)`);
  await store.remove(largeAsset.path);
  const cancelled = snapshot(600);
  let checks = 0;
  await assert.rejects(store.write(context, cancelled, () => ++checks < 2));
  assert.ok(!fs.existsSync(path.join(fixtureDir, store.fileName(cancelled.state.requestId))));
  const duplicate = snapshot(2); duplicate.entries[1] = duplicate.entries[0];
  const dupAsset = await store.write(context, duplicate, () => true);
  await assert.rejects(store.read(context, duplicate.state.requestId, dupAsset, () => true));
  await store.remove(dupAsset.path);
  const truncated = snapshot();
  const truncatedAsset = await store.write(context, truncated, () => true);
  fs.truncateSync(truncatedAsset.path, Number(truncatedAsset.size) - 2);
  truncatedAsset.size = fs.statSync(truncatedAsset.path).size.toString();
  await assert.rejects(store.read(context, truncated.state.requestId, truncatedAsset, () => true));
  await store.remove(truncatedAsset.path);
  cases++;

  const source = new ContinuationManager();
  const receiver = new ContinuationManager();
  cleanupManagers.push(source, receiver);
  const restored = [];
  let account = 'wrong-account'; let exportEnabled = true; let receiveEnabled = true;
  const outgoing = snapshot(); outgoing.state.scene = 'video';
  outgoing.entries[0] = entry(outgoing.state.path + '/movie.mp4');
  outgoing.state.target = outgoing.entries[0].path; outgoing.state.positionMs = 12500; outgoing.state.playing = true;
  let paused = 0; let resumed = 0;
  const page = {
    available: () => exportEnabled, canReceive: () => receiveEnabled, accountIdentity: () => account,
    capture: () => outgoing, sending: value => logs.push(['sending', value]),
    pauseSourcePlayback: async () => paused++, resumeSourcePlayback: async () => resumed++,
    restore: async state => { if (account !== 'correct-account') throw new ContinuationAccountRequired(); restored.push(state); }
  };
  source.initialize(context); source.attach(page);
  const params = {version: 1000010, targetDevice: 'target-device'};
  assert.equal(await source.export(params), 0);
  assert.equal(paused, 1); assert.equal(resumed, 0);
  assert.equal(params.sourceExit, false); assert.equal(params.pageStack, false);
  assert.ok(JSON.stringify(params).length < 1000);
  assert.ok(!JSON.stringify(params).includes('my-nas'));
  receiver.initialize(context); receiver.attach(page); receiver.receive({parameters: params});
  await until(() => storage.get('continuationWaitingForAccount'));
  assert.equal(restored.length, 0);
  for (let i = 0; i < 5; i++) receiver.refresh();
  await turn(); assert.equal(restored.length, 0);
  account = 'correct-account'; receiver.refresh();
  await until(() => restored.length === 1 && !storage.get('continuationPending'));
  assert.equal(restored[0].state.positionMs, 12500);
  assert.equal(nativeObjects.at(-1).observer, null);
  receiver.receive({parameters: params});
  assert.equal(storage.get('continuationPending'), false, 'duplicate completed Want must not reopen a page');
  rejectSave = true;
  assert.equal(await source.export({version: 1000010, targetDevice: 'target-device'}), 0);
  await until(() => storage.get('continuationMessage') === '接续数据同步失败，请在接收设备重试');
  assert.equal(resumed, 0, 'after acceptance, a failed save must not restart source playback over the receiver');
  rejectSave = false;
  rejectJoin = true;
  assert.equal(await source.export({version: 1000010, targetDevice: 'target-device'}), 1);
  assert.equal(resumed, 1, 'pre-acceptance preparation failure restores original playback');
  rejectJoin = false;
  assert.equal(await source.export({version: 1000009, targetDevice: 'target-device'}), 2);
  exportEnabled = false;
  assert.equal(await source.export(params), 1);
  exportEnabled = true;
  receiveEnabled = false;
  const queuedParams = {...params, linkfilesContinuationRequest: 'beeeeeef-1111-4111-8111-111111111111'};
  receiver.receive({parameters: queuedParams});
  assert.equal(storage.get('continuationPending'), true, 'a new Want waits for startup authorization instead of rejecting the old page');
  assert.equal(receiver.incomingId, queuedParams.linkfilesContinuationRequest);
  receiver.cancel();
  receiveEnabled = true;
  let finishJoin;
  delayJoin = new Promise(resolve => finishJoin = resolve);
  const cancelledExport = source.export({version: 1000010, targetDevice: 'target-device'});
  await until(() => source.exportCancel !== null && source.outgoing !== null);
  source.cancel(); assert.equal(await cancelledExport, 1);
  finishJoin(); delayJoin = null;
  await turn(); assert.equal(storage.get('continuationPending'), false);
  // A slow remote save must not keep the target on its launcher. The retained
  // source object is already active; the receiver waits for its restored event.
  let finishSave;
  delaySave = new Promise(resolve => finishSave = resolve);
  const earlyParams = {version: 1000010, targetDevice: 'target-device'};
  let earlyResult = 'blocked';
  const earlyExport = source.export(earlyParams).then(result => { earlyResult = result; });
  await until(() => source.outgoing?.saveStarted); await turn();
  assert.equal(earlyResult, 0, 'allow target launch before the save callback resolves');
  assert.equal(earlyParams.sourceExit, false);
  assert.ok(earlyParams.linkfilesContinuationSession);
  finishSave(); delaySave = null;
  await earlyExport; await turn();
  // An obsolete save rejection cannot overwrite a newer attempt's feedback.
  let failOldSave;
  delaySave = new Promise((_resolve, reject) => failOldSave = reject);
  assert.equal(await source.export({version: 1000010, targetDevice: 'target-device'}), 0);
  delaySave = null;
  assert.equal(await source.export({version: 1000010, targetDevice: 'target-device'}), 0);
  storage.set('continuationMessage', 'new attempt');
  failOldSave(new Error('obsolete save failed')); await turn();
  assert.equal(storage.get('continuationMessage'), 'new attempt');
  // New audio snapshots advertise v2, while v1 directory/image/video stay readable.
  outgoing.state.protocol = 2; outgoing.state.scene = 'audio';
  outgoing.entries[0] = entry(outgoing.state.path + '/song.flac');
  outgoing.state.target = outgoing.entries[0].path; outgoing.state.anchor = outgoing.state.target;
  const audioParams = {version: 1000010, targetDevice: 'target-device'};
  const beforeAudioPause = paused;
  assert.equal(await source.export(audioParams), 0);
  assert.equal(audioParams.linkfilesContinuationProtocol, 2); assert.equal(paused, beforeAudioPause + 1);
  receiver.receive({parameters: audioParams});
  await until(() => restored.length === 2 && !storage.get('continuationPending'));
  assert.equal(restored.at(-1).state.scene, 'audio');
  const beforeAudioResume = resumed; rejectJoin = true;
  assert.equal(await source.export({version: 1000010, targetDevice: 'target-device'}), 1);
  assert.equal(resumed, beforeAudioResume + 1); rejectJoin = false;
  source.destroy(); receiver.destroy();
  cases++;

  // Execute the actual Index adapter methods with controlled repository/UI boundaries.
  const indexText = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
  const start = indexText.indexOf('  private async showTrackedDialog(');
  const end = indexText.indexOf('  private async completeStartupAuthorization', start);
  assert.ok(start > 0 && end > start);
  const compiledAdapter = ts.transpileModule('export class Adapter {\n' + indexText.slice(start, end) + '\n}', {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText;
  const adapterModule = {};
  vm.runInNewContext(compiledAdapter, {exports: adapterModule, ContinuationPolicy: policy,
    ContinuationAccountRequired, DirectoryTimelinePolicy, DirectoryQuery, ContinuationSnapshot,
    ContinuationManager: {shared: () => ({refresh() {}})}, AppStorage, Object, Map, Error, Math});
  const a = new adapterModule.Adapter();
  const sample = snapshot();
  const oldEntries = [entry('/old-file.jpg')];
  const mediaCalls = [];
  Object.assign(a, {
    startupAuthorized: true, startupRestoring: false, continuationDialogCount: 0, screen: 'files', searchSession: null,
    contextMenuEntry: null, pendingDeleteEntryPaths: {}, continuationPendingDeletes: new Set(), continuationAncestorAnchors: new Map(),
    linkId: 'my-nas', navigationRequestId: 1, entries: oldEntries, currentPath: '/home/test/Photos',
    currentRootType: 3, indexedDirectoryKey: '3:/home/test/Photos', directoryTimeline: {complete: true},
    defaultFileViewMode: 'list', fileContentTouchActive: false, offlineCacheMode: false,
    repository: {sessionIdentity: () => 'https://target-relay|uid-1',
      getRootWithCache: async () => ({personal: roots.slice(0, 1), shared: roots.slice(1), personalRootType: 2}),
      listPage: async () => ({entries: sample.entries.slice(0, 1)})},
    isImage: e => e.name.endsWith('.jpg'), isVideo: e => e.name.endsWith('.mp4'), isAudio: e => e.name.endsWith('.flac'),
    discardSearchSession() {}, setCurrentPageState(page, more) {a.currentPageHasMore = more},
    replaceEntries(entries) {a.entries = entries; a.currentDirectoryHasImages = entries.some(e => a.isImage(e));},
    updateTopTitle(title) {a.topTitle = title;}, fileTitle: p => p,
    updateBottomBarVisibility() {}, resetTimelineInteraction() {}, resetPreviewState() {},
    nextRenderFrame: async () => {}, scrollToLocatedEntry: e => mediaCalls.push(['anchor', e.path]),
    openImageViewer: async (...args) => mediaCalls.push(['image', ...args]),
    openVideoPlayer: async (...args) => mediaCalls.push(['video', ...args]),
    openAudioPlayer: async (...args) => mediaCalls.push(['audio', ...args])
  });
  a.audioPlaybackUiVisible = () => a.showAudioPlayer && !a.audioBackgrounded;
  a.videoPlaybackUiVisible = () => a.showVideoPlayer && !a.videoPipBackgrounded;
  assert.equal(a.continuationAvailable(), true);
  let closePrompt;
  a.presentConfirmationDialog = () => new Promise(resolve => closePrompt = resolve);
  const prompt = a.showTrackedDialog({title: 'delete'});
  assert.equal(a.continuationAvailable(), false);
  closePrompt({index: 0}); await prompt;
  assert.equal(a.continuationDialogCount, 0);
  assert.equal(a.continuationAvailable(), true);
  a.continuationContextToken = 0;
  const stalePrompt = a.showTrackedDialog({title: 'stale delete'});
  a.continuationContextToken++;
  closePrompt({index: 1});
  assert.equal((await stalePrompt).index, -1, 'old confirmation cannot mutate the incoming continuation');
  a.selectionMode = true; assert.equal(a.continuationAvailable(), false); a.selectionMode = false;
  a.searchSession = {}; assert.equal(a.continuationAvailable(), false); a.searchSession = null;
  a.directoryTimeline.complete = false; assert.equal(a.continuationAvailable(), false); a.directoryTimeline.complete = true;
  a.timelineIndexing = true; assert.equal(a.continuationAvailable(), true, 'background refresh does not invalidate mounted complete index');
  a.directoryTimeline.complete = false; assert.equal(a.continuationAvailable(), false); a.directoryTimeline.complete = true;
  a.timelineIndexing = false;
  a.continuationPendingDeletes.add("x"); assert.equal(a.continuationAvailable(), false); a.continuationPendingDeletes.delete("x"); a.pendingDeleteEntryPaths.x = false; assert.equal(a.continuationAvailable(), true);
  // A stable image still owns the parent list's input. It must remain exportable.
  const imageEntry = sample.entries[2];
  a.showImageViewer = true; a.viewerInteractionUnlocked = false; a.imageScale = 1;
  a.committedViewerEntry = () => imageEntry;
  assert.equal(a.continuationAvailable(), true);
  a.imageScale = 2; assert.equal(a.continuationAvailable(), false); a.imageScale = 1;
  a.viewerEntryTransitionActive = true; assert.equal(a.continuationAvailable(), false); a.viewerEntryTransitionActive = false;
  a.showImageViewer = false; a.showVideoPlayer = true; a.videoPrepared = true;
  a.videoEntry = entry(sample.state.path + '/clip.mp4'); a.videoSeekPending = false;
  assert.equal(a.continuationAvailable(), true);
  a.videoSeekPending = true; assert.equal(a.continuationAvailable(), false); a.videoSeekPending = false;
  a.showVideoPlayer = false; a.showAudioPlayer = true; a.audioEntry = entry(sample.state.path + '/song.flac');
  a.audioDurationMs = 300000; let audioSeeking = false; let audioReady = true;
  a.audioManager = {isSeeking: () => audioSeeking, isReady: () => audioReady};
  assert.equal(a.continuationAvailable(), true); assert.equal(a.continuationCanReceive(), true,
    'receiver browsing/media context does not block replacement');
  for (const flag of ['audioOpening', 'audioClosing', 'audioControlPending', 'showAudioQueue']) {
    a[flag] = true; assert.equal(a.continuationAvailable(), false, flag); a[flag] = false;
  }
  audioSeeking = true; assert.equal(a.continuationAvailable(), false); audioSeeking = false;
  audioReady = false; assert.equal(a.continuationAvailable(), false); audioReady = true;
  a.audioCurrentMs = 97531; a.audioPlaying = false; a.fileViewMode = 'list'; a.rootKind = 'personal';
  const audioCapture = a.captureContinuation();
  assert.equal(audioCapture.state.protocol, 2); assert.equal(audioCapture.state.scene, 'audio');
  assert.equal(audioCapture.state.target, a.audioEntry.path); assert.equal(audioCapture.state.anchor, a.audioEntry.path);
  assert.equal(audioCapture.state.positionMs, 97531); assert.equal(audioCapture.state.playing, false);
  a.showAudioPlayer = false;
  const originalRepository = a.repository;
  let resets = 0;
  // Native UI closure is tested independently; this adapter test owns the
  // authenticated network and state-commit boundaries.
  a.prepareContinuationPlayback = async () => {};
  a.audioPlaybackUiVisible = () => a.showAudioPlayer && !a.audioBackgrounded;
  a.videoPlaybackUiVisible = () => a.showVideoPlayer && !a.videoPipBackgrounded;
  a.prepareForContinuation = () => { resets++; a.navigationRequestId++; a.searchSession = null; };
  a.repository = {...originalRepository, sessionIdentity: () => 'https://target-relay|another-uid'};
  await assert.rejects(a.restoreContinuation(sample, () => true), error => error instanceof ContinuationAccountRequired);
  assert.equal(a.entries, oldEntries);
  a.repository = {...originalRepository, listPage: async () => {throw new Error('permission denied')}};
  await assert.rejects(a.restoreContinuation(sample, () => true)); assert.equal(a.entries, oldEntries);
  a.repository = originalRepository;
  await a.restoreContinuation(sample, () => false); assert.equal(a.entries, oldEntries);
  sample.state.scene = 'image'; sample.state.target = sample.entries[2].path;
  sample.state.view = 'waterfall';
  await a.restoreContinuation(sample, () => true);
  assert.ok(resets > 0, 'same-account incoming context replaces the previous browsing scene');
  assert.equal(a.entries.length, 3);
  assert.deepEqual(Array.from(a.navigationStack), ['', '/home/test']);
  assert.deepEqual(Array.from(a.navigationRootTypeStack), [2, 3]);
  assert.equal(a.continuationAncestorAnchors.get('/home/test'), sample.state.path);
  assert.equal(a.navigationEntryStack.length, 0);
  assert.equal(a.fileViewMode, 'waterfall');
  assert.equal(mediaCalls.at(-1)[0], 'image'); assert.equal(mediaCalls.at(-1)[3], true);
  const video = snapshot(); video.entries[1] = entry(video.state.path + '/clip.mp4');
  video.state.scene = 'video'; video.state.target = video.entries[1].path;
  video.state.positionMs = 54321; video.state.playing = false;
  await a.restoreContinuation(video, () => true);
  assert.equal(mediaCalls.at(-1)[0], 'video');
  assert.equal(mediaCalls.at(-1)[2], 54321); assert.equal(mediaCalls.at(-1)[3], false);
  const audio = snapshot(); audio.entries[1] = entry(audio.state.path + '/song.flac');
  Object.assign(audio.state, {protocol: 2, scene: 'audio', target: audio.entries[1].path,
    anchor: audio.entries[1].path, positionMs: 97531, playing: false});
  policy.validate(audio.state);
  await a.restoreContinuation(audio, () => true);
  assert.equal(mediaCalls.at(-1)[0], 'audio');
  assert.equal(mediaCalls.at(-1)[2], false); assert.equal(mediaCalls.at(-1)[3], 97531); assert.equal(mediaCalls.at(-1)[4], false);
  assert.ok(mediaCalls.some(call => call[0] === 'anchor' && call[1] === audio.state.target));
  assert.deepEqual(Array.from(a.navigationStack), ['', '/home/test']);
  assert.equal(a.continuationAncestorAnchors.get(''), '/home/test');
  assert.equal(a.continuationAncestorAnchors.get('/home/test'), audio.state.path);
  audio.state.protocol = 1; assert.throws(() => policy.validate(audio.state)); audio.state.protocol = 2;
  audio.state.target = audio.entries[0].path;
  await assert.rejects(a.restoreContinuation(audio, () => true), /接续文件类型无效/);
  cases++;

  const backStart = indexText.indexOf('  private async goBack(): Promise<void>');
  const backEnd = indexText.indexOf('  private async downloadEntry(', backStart);
  const backModule = {};
  vm.runInNewContext(ts.transpileModule('export class Back {\n' + indexText.slice(backStart, backEnd) + '\n}', {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText, {exports: backModule, DirectoryTimelinePolicy, DirectoryQuery, Math, Error});
  let indexReads = 0;
  const parentEntries = Array.from({length: 1300}, (_, i) => entry('/home/test/file-' + i + '.jpg'));
  parentEntries.push(entry('/home/test/Photos', true));
  Object.assign(a, {
    shouldRestoreSearch: () => false,
    transitionBackFileContent: async (items, _view, _path, commit) => commit(items),
    applyPreferredViewMode() {}, updateDirectoryCount() {}, showPageTransition: false,
    repository: {...originalRepository,
      listPage: async () => ({entries: parentEntries.slice(0, 200), pageIndex: 1, hasMore: true, totalCount: parentEntries.length}),
      ensureDirectoryIndex: async () => {indexReads++; return {entries: parentEntries, timeline: {complete: true}};}}
  });
  await backModule.Back.prototype.goBack.call(a);
  assert.equal(indexReads, 1); assert.equal(a.entries.length, 1301);
  assert.equal(a.currentPath, '/home/test'); assert.equal(a.currentPageHasMore, false);
  assert.equal(mediaCalls.at(-1)[1], '/home/test/Photos');
  assert.deepEqual(Array.from(a.navigationStack), ['']);
  await backModule.Back.prototype.goBack.call(a);
  assert.equal(indexReads, 1, 'root return reuses target-authorized roots');
  assert.equal(a.currentPath, ''); assert.equal(a.currentRootType, 2);
  assert.equal(mediaCalls.at(-1)[1], '/home/test');
  cases++;

  const abilityExports = {};
  const abilityEvents = [];
  let insideLifecycle = false;
  const abilityContext = {
    config: {}, restoreWindowStage: () => {assert.ok(insideLifecycle); abilityEvents.push('restore-window');},
    getApplicationContext: () => ({setColorMode() {}})
  };
  const abilityKit = {...native['@kit.AbilityKit'],
    UIAbility: class { constructor() {this.context = abilityContext;} },
    ConfigurationConstant: {ColorMode: {COLOR_MODE_NOT_SET: -1}},
    AbilityConstant: {...native['@kit.AbilityKit'].AbilityConstant, LaunchReason: {CONTINUATION: 7}}
  };
  const transport = {initialize: () => abilityEvents.push('initialize'), receive: () => abilityEvents.push('receive'),
    export: async () => 0, destroy: () => abilityEvents.push('destroy')};
  const startup = {prepare: () => abilityEvents.push('privacy-prepare'), beginInitial: async () => abilityEvents.push('privacy-start')};
  const abilityJs = ts.transpileModule(fs.readFileSync('entry/src/main/ets/entryability/EntryAbility.ets', 'utf8'), {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText;
  vm.runInNewContext(abilityJs, {exports: abilityExports, AppStorage, LocalStorage: class {},
    require: key => {
      if (key === '@kit.AbilityKit') return abilityKit;
      if (key === '@kit.ArkUI') return {window: {}};
      if (key === '@kit.PerformanceAnalysisKit') return {hilog: {info() {}, error() {}}};
      if (key.endsWith('/ContinuationManager')) return {ContinuationManager: {shared: () => transport}};
      if (key.endsWith('/StartupAuthorization')) return {StartupAuthorization: {shared: () => startup}};
      if (key.endsWith('/IncomingShareManager')) return {IncomingShareManager: {shared: () => ({receive() {}, destroy() {}})}};
      if (key.endsWith('/TransferBackgroundManager')) return {TransferBackgroundManager: {shared: () => ({destroy: async () => {}, setForeground() {}})}};
      throw new Error(key);
    }});
  const ability = new abilityExports.default();
  insideLifecycle = true; ability.onCreate({parameters: {}}, {launchReason: 7}); insideLifecycle = false;
  const stage = {getMainWindow: () => Promise.reject(new Error('no host window')),
    loadContent: (_name, callback) => {abilityEvents.push('load-page'); callback({code: 0});}};
  ability.onWindowStageRestore(stage);
  insideLifecycle = true; ability.onNewWant({parameters: {}}, {launchReason: 7}); insideLifecycle = false;
  ability.onWindowStageRestore(stage);
  assert.equal(abilityEvents.filter(e => e === 'privacy-prepare').length, 1);
  assert.equal(abilityEvents.filter(e => e === 'load-page').length, 1, 'hot restore must retain existing page');
  assert.equal(abilityEvents.filter(e => e === 'privacy-start').length, 1);
  assert.equal(abilityEvents.filter(e => e === 'receive').length, 2);
  assert.equal(await ability.onContinue({}), 0);
  ability.onDestroy();
  await turn();
  cases++;

  assert.equal(positions.size, 0, 'all file handles closed');
  console.log(`Continuation regression passed (${cases} groups: validation, short IO/UTF-8, 50k gallery, transport cancellation/account, actual page adapter/dialog, lazy ancestor Back, cold/hot Ability lifecycle).`);
}
run().catch(error => {console.error(error); process.exitCode = 1;}).finally(() => {
  cleanupManagers.forEach(manager => manager.destroy());
  // Only files created by this regression, inside its fixed temp directory.
  for (const name of fs.readdirSync(fixtureDir)) {
    if (/^linkfiles-continuation-[0-9a-f-]{36}\.jsonl$/.test(name)) fs.unlinkSync(path.join(fixtureDir, name));
  }
});

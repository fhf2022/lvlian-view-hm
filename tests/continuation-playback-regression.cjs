const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const exported = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' +
  ['prepareContinuationPlayback', 'audioPlaybackUiVisible', 'onAudioPlaybackNavigationRequested',
    'captureMediaPlaybackOrigin', 'restoreVideoPipOrigin', 'videoNavigationEntries',
    'handleVideoPipStateChange'].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exported, AudioCoverRect: class {},
  console: { info() {} }, PiPWindow: { PiPState: { STARTED: 2, STOPPED: 4, ABOUT_TO_RESTORE: 5, ERROR: 6 } },
  ContinuationManager: { shared: () => ({ cancel() {} }) } });
function make() {
  const page = new exported.Page(), calls = [];
  Object.assign(page, {
    showAudioPlayer: true, audioPlaying: true, audioBackgrounded: false,
    audioReturnHiddenPath: '', notifyEntryChanged() {},
    audioEntry: { path: '/music/song.flac' }, audioOriginScope: 'same-account',
    showVideoPlayer: false, videoPlaying: true, videoPipBackgrounded: false,
    audioCloseWork: Promise.resolve(), videoCloseWork: Promise.resolve(),
    repository: { sessionIdentity: () => 'same-account' },
    captureMediaPlaybackOrigin: () => ({ path: '/music' }),
    closeAudioPlayer: () => { calls.push('close-audio'); page.showAudioPlayer = false; page.audioBackgrounded = false; },
    closeVideoPlayer: () => { calls.push('close-video'); page.showVideoPlayer = false; page.videoPipBackgrounded = false; },
    toggleVideoPip: async () => { calls.push('pip'); page.videoPipBackgrounded = true; },
    restoreMediaPlaybackOrigin: origin => calls.push(['restore', origin.path]),
    updateBottomBarVisibility() {}, isVideo: entry => entry.path.endsWith('.mp4')
  });
  return { page, calls };
}
(async () => {
  for (const scene of ['directory', 'image']) {
    let state = make();
    await state.page.prepareContinuationPlayback(scene, () => true);
    assert.equal(state.page.showAudioPlayer, true, 'keep the original player/session alive');
    assert.equal(state.page.audioBackgrounded, true);
    assert.equal(state.page.audioPlaybackUiVisible(), false, 'hidden audio never owns directory input');
    const origin = state.page.audioBackgroundOrigin;
    await state.page.prepareContinuationPlayback(scene, () => true);
    assert.equal(state.page.audioBackgroundOrigin, origin, 'a later receive must not overwrite the original media directory');
    assert.deepEqual(state.calls, []);
    state.page.onAudioPlaybackNavigationRequested();
    assert.equal(state.page.audioBackgrounded, false);
    assert.deepEqual(state.calls, [['restore', '/music']]);

    state = make(); state.page.showAudioPlayer = false; state.page.showVideoPlayer = true;
    await state.page.prepareContinuationPlayback(scene, () => true);
    assert.deepEqual(state.calls, ['pip']);
    assert.equal(state.page.showVideoPlayer, true);
    await state.page.prepareContinuationPlayback(scene, () => true);
    assert.deepEqual(state.calls, ['pip'], 'existing PiP is not toggled off by another receive');
  }
  for (const scene of ['audio', 'video']) {
    const state = make(); state.page.showVideoPlayer = true; state.page.videoPipBackgrounded = true;
    await state.page.prepareContinuationPlayback(scene, () => true);
    assert.deepEqual(state.calls, ['close-audio', 'close-video'], 'new AV closes both prior media owners');
    assert.equal(state.page.audioBackgrounded, false);
  }
  let state = make(); state.page.showAudioPlayer = false; state.page.showVideoPlayer = true;
  state.page.toggleVideoPip = async () => {};
  await state.page.prepareContinuationPlayback('image', () => true);
  assert.equal(state.page.showVideoPlayer, false, 'unavailable PiP cannot cover the incoming image');
  state = make(); state.page.audioOriginScope = 'old-account'; state.page.audioBackgrounded = true;
  state.page.onAudioPlaybackNavigationRequested(); assert.deepEqual(state.calls, [], 'no cross-account restore');
  state = make(); state.page.videoPipBackgrounded = true;
  state.page.videoPipOrigin = { entries: [{ path: '/old/a.mp4' }] };
  state.page.entries = [{ path: '/incoming/b.mp4' }];
  assert.equal(state.page.videoNavigationEntries()[0].path, '/old/a.mp4', 'PiP next/previous uses its own directory');
  state.page.showVideoPlayer = true;
  state.page.showImmersiveToast = () => {};
  state.page.handleVideoPipStateChange(6, 'error');
  assert.equal(state.page.showVideoPlayer, false, 'PiP failure cannot resurface the old full-screen video');
  console.log('PASS continuation playback: directory/image keeps audio or PiP, AV replaces old sessions, restore/account and PiP playlist boundaries');
})().catch(error => { console.error(error); process.exitCode = 1; });

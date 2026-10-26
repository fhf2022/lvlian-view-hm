const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict'), ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) { const a = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm')); assert.ok(a >= 0, name); const b = source.slice(a + 1).search(/^  (?:private |@Builder)/m); return source.slice(a, a + b + 1); }
const ex = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' + ['continuationCanReceive', 'prepareForContinuation', 'closePageDialogs', 'releaseViewerForReplacement'].map(method).join('\n') + '\n}', { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText, { exports: ex });
for (const scene of ['files', 'settings', 'downloads', 'image', 'audio', 'video', 'search', 'selection', 'destination']) {
    const p = new ex.Page(), closed = [];
    Object.assign(p, { startupAuthorized: true, startupRestoring: false, continuationSending: false, screen: scene, isBusy: true, isNavigating: true, showImageViewer: true, showAudioPlayer: true, showVideoPlayer: true, showDestinationPicker: true, showSearch: true, selectionMode: true, showAlbumUpload: true, continuationContextToken: 0, pageDialogClosers: new Set([() => closed.push('dialog')]), navigationRequestId: 7, directoryIndexRequestToken: 9, destinationPickerCloseToken: 0, destinationLoadToken: 0, viewerReturnOverlayToken: 3, viewerGeneration: 5, pendingOpenEntry: { path: '/old' }, pendingContextAction: () => { throw Error('old menu action must not run'); }, destinationDataSource: { replace: () => { } }, viewerPrefetchCoordinator: { onViewerClosed: () => closed.push('prefetch') }, viewerReturnOverlayMountResolve: () => closed.push('mount'), cancelDropImport() { }, cancelFileTransition: () => closed.push('transition'), endDragSelection: () => closed.push('range'), exitSelectionMode: () => { p.selectionMode = false; }, discardSearchSession: () => { p.showSearch = false; p.searchSession = null; }, closeActionMenu: () => closed.push('context'), closeFileSortMenu() { }, closeSelectionMoreMenu() { }, closeImageMoreMenu() { }, finishCloseImageViewer: restore => { assert.equal(restore, false); p.viewerClosePending = false; closed.push('image'); }, closeAudioPlayer: immediate => { assert.equal(immediate, true); p.showAudioPlayer = false; closed.push('audio'); }, closeVideoPlayer: () => { p.showVideoPlayer = false; closed.push('video'); } });
    assert.equal(p.continuationCanReceive(), true, scene + ' context cannot reject incoming replacement');
    p.prepareForContinuation();
    assert.equal(p.navigationRequestId, 8);
    assert.equal(p.pendingOpenEntry, null);
    assert.equal(p.pendingContextAction, null);
    for (const key of ['showImageViewer', 'showAudioPlayer', 'showVideoPlayer', 'showSearch', 'selectionMode', 'showDestinationPicker', 'showAlbumUpload', 'isBusy', 'isNavigating'])
        assert.equal(p[key], false, key);
    assert.ok(closed.includes('image') && closed.includes('audio') && closed.includes('video'));
    p.startupAuthorized = false;
    assert.equal(p.continuationCanReceive(), false, 'privacy authorization remains required');
}
console.log('PASS incoming continuation replaces every browsing/media/modal context, invalidates old navigation callbacks and retains authorization gate');

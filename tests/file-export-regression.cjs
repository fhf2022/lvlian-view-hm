const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict'), ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) { const a = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm')); assert.ok(a >= 0, name); const b = source.slice(a + 1).search(/^  (?:private |@Builder)/m); return source.slice(a, a + b + 1); }
class Data {
    constructor() { this.records = []; }
    addRecord(r) { this.records.push(r); }
}
class File {
}
class Image extends File {
}
class Video extends File {
}
class Audio extends File {
}
let pins = new Map(), timers = [];
const ex = {};
vm.runInNewContext(ts.transpileModule('export class Export {\n' + ['startSelectedFileDrag', 'cacheGestureEntries', 'pinTransferCacheTargets', 'cancelSelectedFileDrag', 'beginDragSelection'].map(method).join('\n') + '\n}', { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText, { exports: ex, unifiedDataChannel: { UnifiedData: Data, File, Image, Video, Audio }, fileUri: { getUriFromPath: p => 'file://' + p }, CacheManager: { exists: p => !!p, cachePath: (_d, _n, k) => '/cache' + k }, StorageBudget: { pin: p => pins.set(p, (pins.get(p) || 0) + 1), unpin: p => pins.set(p, pins.get(p) - 1) }, console, setTimeout: fn => { timers.push(fn); return timers.length; }, clearTimeout: id => { timers[id - 1] = null; } });
const tick = async () => { for (let i = 0; i < 40; i++)
    await Promise.resolve(); };
function make() { const p = new ex.Export(), entries = Array.from({ length: 6 }, (_, i) => ({ name: i + '.jpg', path: '/photos/' + i, isDirectory: false })), drags = []; let downloads = 0, active = 0, max = 0; Object.assign(p, { selectionMode: true, fileContentTouchActive: true, fileExportPreparing: false, fileExportDragging: false, fileExportToken: 0, selectedDragTimer: 0, repository: { sessionIdentity: () => 'nas|user' }, selectedEntriesInCurrentDirectory: () => entries, filterGestureTransferEntries: async (e) => ({ entries: e }), showImmersiveToast() { }, reportError(e) { throw e; }, fileViewMode: 'grid', gridThumbnailComponentId: e => 'grid:' + e.path, originalCacheKey: e => e.path, isImage: () => true, isAudio: () => false, isVideo: () => false, getUIContext: () => ({ getComponentSnapshot: () => ({ createFromBuilder: async () => ({ release: async () => { } }) }), getDragController: () => ({ executeDrag: async (preview, info) => { assert.ok(preview.pixelMap); drags.push(info); } }) }), ensureCachedFile: async (e) => { downloads++; max = Math.max(max, ++active); await Promise.resolve(); active--; return '/cache' + e.path; }, isSelected: () => true, startDragSelectionRange() { p.ranges = (p.ranges || 0) + 1; } }); return { p, entries, drags, stats: () => ({ downloads, max }) }; }
(async () => {
    let h = make();
    await h.p.startSelectedFileDrag(h.entries[0], { fingerList: [{ id: 2 }] });
    assert.equal(h.drags.length, 1);
    assert.equal(h.drags[0].pointerId, 2);
    assert.equal(h.drags[0].data.records.length, 6);
    assert.equal(h.stats().max, 2, 'same two cache workers as existing share path');
    assert.ok(h.drags[0].data.records.every(r => r instanceof Image && r.uri.startsWith('file://')));
    assert.deepEqual(h.drags[0].data.records.map(r => r.details.name), h.entries.map(e => e.name),
        'original display names accompany real file URIs; receiving apps may still use URI basenames');
    assert.ok([...pins.values()].every(v => v === 0), 'all pins balanced after drag ends');
    h = make();
    let release;
    const held = new Promise(r => release = r);
    let calls = 0;
    h.p.ensureCachedFile = async (e) => { calls++; await held; return '/cache' + e.path; };
    const job = h.p.startSelectedFileDrag(h.entries[0], { fingerList: [{ id: 0 }] });
    await tick();
    assert.equal(calls, 2);
    h.p.fileContentTouchActive = false;
    h.p.cancelSelectedFileDrag();
    assert.equal(h.p.fileExportPreparing, true, 'cancel retains physical worker ownership until cleanup');
    release();
    await job;
    assert.equal(calls, 2, 'canceled preparation cannot start further downloads');
    assert.equal(h.drags.length, 0);
    assert.ok([...pins.values()].every(v => v === 0));
    h = make();
    h.entries[1].isDirectory = true;
    await h.p.startSelectedFileDrag(h.entries[0], { fingerList: [{ id: 0 }] });
    assert.equal(h.stats().downloads, 0, 'unsupported mixed selection never silently exports a partial subset');
    h = make();
    h.p.beginDragSelection(h.entries[0], 0, { fingerList: [{ id: 0 }] });
    assert.equal(h.p.ranges || 0, 0, 'selected hold does not invert the anchor before export');
    h.p.cancelSelectedFileDrag();
    assert.equal(timers.filter(Boolean).length, 0, 'lift cancels pending long-hold export');
    h.p.isSelected = () => false;
    h.p.beginDragSelection(h.entries[0], 0, { fingerList: [{ id: 0 }] });
    assert.equal(h.p.ranges, 1, 'unselected range gesture retains its immediate path');
    console.log('PASS file export: selected hold, native multi-file UDMF/image URIs, real preview, two cache workers, pins, cancel ownership and range-selection path');
})().catch(e => { console.error(e); process.exitCode = 1; });

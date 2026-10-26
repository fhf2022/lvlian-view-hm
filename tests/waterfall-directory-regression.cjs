// node tests/waterfall-directory-regression.cjs <SDK typescript.js>
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const compile = (source, bindings = {}) => {
    const exports = {};
    vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
            target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
        } }).outputText, { exports, console, ...bindings });
    return exports;
};
const { WaterfallBatchCoordinator } = compile(fs.readFileSync('entry/src/main/ets/media/WaterfallBatchCoordinator.ets', 'utf8'));
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
    const start = source.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
    assert.ok(start >= 0, name);
    const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
    return source.slice(start, start + end + 1);
}
const names = ['ensureWaterfallStarted', 'resetPreviewState', 'resetWaterfallDirectoryState', 'finishPreparedFileTransition'];
const { Page } = compile('export class Page {\n' + names.map(method).join('\n') + '\n}');
const tick = async () => { for (let i = 0; i < 120; i++)
    await Promise.resolve(); };
function harness() {
    const h = new Page(), frames = [], geometry = [];
    let published = [];
    Object.assign(h, {
        screen: 'files', fileViewMode: 'waterfall', waterfallEntries: Array.from({ length: 36 }, (_, i) => ({ path: '/camera/' + i })),
        waterfallAnchor: null, targetLocateEntryPath: '', resetPreviewAfterPageTransition: true,
        pageTransitionToken: 5, showPageTransition: true, waterfallAspectEpoch: 0, previewGeneration: 0,
        previewRecoveryAttempts: new Map(), previewReloadPaths: new Set(), previewQueue: { cancelPending() { } },
        pendingVisibleLoads: new Map(), postRenderFrame: fn => frames.push(fn), schedulePreviewWarmup() { }, resetFileListScroll() { }
    });
    h.waterfallBatches = new WaterfallBatchCoordinator({
        async geometry(entry) { geometry.push(entry.path); return { displayWidth: 1200, displayHeight: 1600 }; },
        async thumbnail() { }, originals() { }, evict() { }, changed() { },
        publish() { published = h.waterfallBatches.published(); }
    });
    // External resource cleanup boundary; production resetPreviewState and
    // directory admission/finish methods above execute unchanged.
    h.stopWaterfallPipeline = () => { h.waterfallBatches.reset(); published = []; };
    return { h, geometry, count: () => published.length, async frame() {
            const callbacks = frames.splice(0);
            callbacks.forEach(fn => fn());
            await tick();
        } };
}
(async () => {
    const first = harness();
    first.h.ensureWaterfallStarted();
    await tick();
    assert.equal(first.geometry.length, 0, 'incoming data must not start before pending transition cleanup');
    first.h.finishPreparedFileTransition(5);
    await tick();
    assert.equal(first.count(), 0);
    await first.frame();
    assert.equal(first.count(), 12, 'same-size native surface must regain a group after final cleanup without onAreaChange');
    assert.equal(first.geometry.length, 12, 'one start, not a canceled metadata pass followed by another');
    first.h.ensureWaterfallStarted();
    await first.frame();
    assert.equal(first.geometry.length, 12, 'native area callback cannot duplicate the explicit restart');
    // Resetting an already published group is also followed by a valid start.
    first.h.resetPreviewState(false);
    assert.equal(first.count(), 0);
    await first.frame();
    assert.equal(first.count(), 12);
    const stale = harness();
    stale.h.finishPreparedFileTransition(4);
    await stale.frame();
    assert.equal(stale.geometry.length, 0, 'stale finish cannot clear or start the current directory');
    for (const change of [h => { h.fileViewMode = 'grid'; }, h => { h.screen = 'login'; }]) {
        const away = harness();
        away.h.finishPreparedFileTransition(5);
        change(away.h);
        await away.frame();
        assert.equal(away.geometry.length, 0, 'late restart must observe the current page and mode');
    }
    console.log('PASS waterfall directory lifecycle: staged cleanup, fast cached admission, same-size reentry, one restart and stale/mode/page guards');
})().catch(error => { console.error(error); process.exitCode = 1; });

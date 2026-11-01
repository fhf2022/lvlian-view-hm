const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2]);

function compile(source, dependencies = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports, require: name => dependencies[name], Number, Math });
  return exports;
}
const header = compile(fs.readFileSync('entry/src/main/ets/ui/HeaderStyle.ets', 'utf8'));
const { TaskPanelStyle: style } = compile(fs.readFileSync('entry/src/main/ets/ui/TaskPanelStyle.ets', 'utf8'), {
  './HeaderStyle': header, '@kit.ArkUI': { curves: {} }
});

assert.equal(style.width(360), 324);
assert.equal(style.width(1280), 720);
assert.equal(style.width(360, 0.84), 302.4);
assert.equal(style.width(1280, 0.84), 720);
assert.equal(style.dialogWidth(1280), 420, 'short forms have their own compact maximum');
assert.equal(style.dialogWidth(360), 302.4, 'phone dialog keeps its existing proportion');
assert.equal(style.width(1280, .9, true), 420, 'confirmation stays compact on tablets');
assert.equal(style.width(360, .9, true), 324, 'compact confirmation still respects phone edges');
assert.equal(style.height(960, 24, 16, true), 380, 'confirmation does not fill a selection-sized panel');
assert.equal(style.height(220, 24, 16, true), 148, 'compact panel keeps the same small-window fallback');
assert.equal(style.height(780, 0, 0), 546);
assert.equal(style.height(360, 24, 16), 288, 'short-window limit wins over preferred 420 minimum');
assert.equal(style.height(220, 24, 16), 148, 'keyboard-sized viewport stays within usable bounds');
for (let width = 0; width <= 4096; width += 13) {
  const card = style.width(width);
  assert.ok(Number.isFinite(card) && card >= 0 && card <= Math.max(0, width - 32));
  assert.ok(card <= 720);
}
for (let height = 0; height <= 2300; height += 11) {
  for (const [top, bottom] of [[0, 0], [36, 24], [80, 52], [0, 350]]) {
    const card = style.height(height, top, bottom);
    assert.ok(Number.isFinite(card) && card >= 0 && card <= Math.max(0, height - top - bottom - 32));
  }
}
for (const invalid of [NaN, Infinity, -Infinity, -1]) {
  assert.equal(style.width(invalid), 0);
  assert.equal(style.height(invalid, 0, 0), 0);
}

const pickerSource = fs.readFileSync('entry/src/main/ets/components/AlbumUploadPicker.ets', 'utf8');
const start = pickerSource.indexOf('  private async select(');
const end = pickerSource.indexOf('\n  @Builder', start);
let permission, album, reads;
class Source {
  requestPermission() { return permission; }
  selectedAlbum() { reads++; return album; }
}
const pickerExports = {};
vm.runInNewContext(ts.transpileModule('export class Picker {\n' + pickerSource.slice(start, end) + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: pickerExports, LocalAlbumSource: Source, getContext: () => ({}), LocalAlbumPermissionError: Error });
function deferred() {
  let resolve, reject;
  const promise = new Promise((r, j) => { resolve = r; reject = j; });
  return { promise, resolve, reject };
}
function picker() {
  const p = new pickerExports.Picker();
  Object.assign(p, { loading: false, visible: true, generation: 0, notices: [],
    onNotice: text => p.notices.push(text), onSelected: () => { p.selected = true; } });
  reads = 0; permission = Promise.resolve(); album = Promise.resolve({ name: 'Test' });
  return p;
}
const sheetSource = fs.readFileSync('entry/src/main/ets/components/AlbumUploadSheet.ets', 'utf8');
const sheetStart = sheetSource.indexOf('  private async select(');
const sheetExports = {};
vm.runInNewContext(ts.transpileModule('export class Sheet {\n' +
  sheetSource.slice(sheetStart, sheetSource.indexOf('\n  @Builder', sheetStart)) + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: sheetExports, LocalAlbumSource: Source, getContext: () => ({}) });
function sheet() {
  const p = new sheetExports.Sheet();
  Object.assign(p, { visible: true, generation: 0, loading: false, starting: false,
    startPending: false, selected: { uri: 'album:1', name: 'Test' }, notices: [],
    onNotice: text => p.notices.push(text) });
  permission = Promise.resolve(); album = Promise.resolve({ name: 'Updated' }); reads = 0;
  return p;
}
(async () => {
  const invalid = picker();
  await invalid.select({ uri: '' });
  assert.equal(invalid.notices.length, 1, 'invalid album uses page feedback');
  assert.equal(reads, 0);
  const failed = picker();
  permission = Promise.reject(new Error('Permission denied'));
  await failed.select({ uri: 'album:1' });
  assert.equal(failed.notices[0], 'Permission denied');
  assert.equal(failed.loading, false, 'refusal leaves album selection retryable');
  permission = Promise.resolve();
  await failed.select({ uri: 'album:1' });
  assert.equal(failed.selected, true, 'selecting an album again still runs the official permission request');
  const closed = picker(), permissionWait = deferred();
  permission = permissionWait.promise;
  const pending = closed.select({ uri: 'album:1' });
  closed.visible = false; closed.generation++;
  permissionWait.resolve(); await pending;
  assert.equal(reads, 0, 'closing during system permission request cannot reopen confirmation');
  const replaced = picker(), albumWait = deferred();
  album = albumWait.promise;
  const reading = replaced.select({ uri: 'album:2' });
  await Promise.resolve();
  replaced.visible = false; replaced.generation++;
  albumWait.resolve({ name: 'Old' }); await reading;
  assert.equal(replaced.selected, undefined, 'late album response cannot populate a closed/replaced panel');
  const selected = picker();
  await selected.select({ uri: 'album:3' });
  assert.equal(selected.selected, true);
  assert.equal(selected.loading, false);
  const stale = picker(), staleWait = deferred();
  album = staleWait.promise;
  const staleRead = stale.select({ uri: 'album:4' });
  for (let i = 0; i < 4; i++) await Promise.resolve();
  assert.equal(reads, 1);
  stale.visible = false; stale.generation++;
  staleWait.reject(new Error('Late failure')); await staleRead;
  assert.equal(stale.notices.length, 0, 'closed picker must not emit delayed error feedback');
  const refresh = sheet(), refreshWait = deferred();
  album = refreshWait.promise;
  const refreshing = refresh.select('album:1', 'Test');
  for (let i = 0; i < 4; i++) await Promise.resolve();
  assert.equal(reads, 1);
  refresh.visible = false; refresh.generation++;
  refreshWait.reject(new Error('Late refresh failure')); await refreshing;
  assert.equal(refresh.notices.length, 0);
  assert.equal(refresh.selected.name, 'Test', 'closed sheet cannot replace its album');
  const start = sheet();
  let attempts = 0;
  start.onStart = async () => { if (++attempts === 1) throw new Error('NAS unavailable'); };
  await start.start();
  assert.equal(start.notices[0], 'NAS unavailable');
  assert.equal(start.visible, true); assert.equal(start.startPending, false);
  await start.start();
  assert.equal(attempts, 2); assert.equal(start.visible, false);
  console.log('PASS task panels: bounded geometry, shared error feedback, permission retry, stale errors/reads suppressed and upload preparation retry');
})().catch(error => { console.error(error); process.exitCode = 1; });

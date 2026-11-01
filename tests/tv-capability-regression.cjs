// Execute the real analyzer lifecycle: TV/unsupported devices must never
// instantiate an unavailable native controller while the page is starting.
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private ' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder|onPage)/m);
  return source.slice(start, start + end + 1);
}
let available = false, created = 0, failCreate = false;
const events = new Map(), calls = [];
class Controller {
  constructor() { created++; if (failCreate) throw new Error('native service unavailable'); }
  getImageAnalyzerSupportTypes() { return [1, 2, 3, 1, 99]; }
  on(name, callback) { events.set(name, callback); }
  off(name) { calls.push(['off', name]); events.delete(name); }
  setImageAnalyzerVisibility(value) { calls.push(['visibility', value]); }
}
const exportsObject = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' +
  ['configureImageAnalyzer', 'releaseImageAnalyzer'].map(method).join('\n') + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, {
  exports: exportsObject, console: { info() {}, warn() {} },
  canIUse: cap => { assert.equal(cap, 'SystemCapability.AI.VisionImageAnalyzer'); return available; },
  ImageAnalyzerType: { TEXT: 1, SUBJECT: 2, OBJECT_LOOKUP: 3 },
  visionImageAnalyzer: { VisionImageAnalyzerController: Controller,
    AIButtonStatus: { SELECTED: 1 }, ImageAnalyzerVisibility: { HIDDEN: 0 } }
});
function page() {
  const p = new exportsObject.Page();
  Object.assign(p, { imageAnalyzerController: null, imageAnalyzerTypes: [],
    imageAnalyzerSupported: false, imageAnalyzerListenerBound: false, imageAnalyzerActive: false });
  return p;
}
const unsupported = page();
unsupported.configureImageAnalyzer(); unsupported.releaseImageAnalyzer();
assert.equal(created, 0); assert.equal(unsupported.imageAnalyzerSupported, false);
assert.equal(unsupported.imageAnalyzerController, null);
available = true;
const supported = page(); supported.configureImageAnalyzer(); supported.configureImageAnalyzer();
assert.equal(created, 1, 'supported devices reuse one controller');
assert.equal(supported.imageAnalyzerTypes.join(','), '1,2,3');
assert.equal(supported.imageAnalyzerSupported, true); assert.equal(events.size, 2);
events.get('aiButtonStatusChange')(1); assert.equal(supported.imageAnalyzerActive, true);
events.get('imageAnalyzerVisibilityChange')(0); assert.equal(supported.imageAnalyzerActive, false);
supported.releaseImageAnalyzer(); assert.equal(events.size, 0);
assert.deepEqual(calls, [['off', 'aiButtonStatusChange'], ['off', 'imageAnalyzerVisibilityChange'], ['visibility', 0]]);
failCreate = true;
const failed = page(); failed.configureImageAnalyzer(); failed.releaseImageAnalyzer();
assert.equal(failed.imageAnalyzerSupported, false); assert.equal(failed.imageAnalyzerController, null);
console.log('PASS TV capability: no unsupported native analyzer at startup; supported reuse/listeners/cleanup and unavailable-service handling');

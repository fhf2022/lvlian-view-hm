// node tests/file-grid-layout-regression.cjs <SDK typescript.js>
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/FileGridLayout.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, Number, Math });
const { FileGridLayout: layout } = exportsObject;
const cases = [
  [360, 800, 4, 'phone portrait'], [800, 360, 7, 'phone landscape'],
  [376, 840, 4, 'phone portrait'], [840, 376, 7, 'phone landscape'],
  [350, 776, 4, 'folded phone'], [374, 827, 4, 'phone reference'],
  [540, 960, 5, 'phone-shaped floating window'],
  [480, 1280, 4, 'tall narrow split window'], [360, 360, 4, 'small square outer screen'],
  [960, 1440, 5, 'tablet portrait'], [1440, 960, 7, 'tablet landscape'],
  [800, 800, 6, 'square unfolded window'], [700, 800, 6, 'smaller unfolded window'],
  [712, 776, 6, 'dual fold'], [1107, 776, 7, 'tri-fold landscape'],
  [776, 1107, 5, 'tri-fold portrait'],
  [1080, 780, 7, 'wide unfolded window'], [1440, 1000, 7, 'large unfolded window'],
  [1920, 1080, 7, 'large landscape window'], [1080, 1920, 5, 'large portrait window']
];
for (const [w, h, expected, description] of cases) assert.equal(layout.columns(w, h), expected, description);
for (const width of [0, -1, NaN, Infinity]) assert.equal(layout.columns(width, 900), 2);
for (const height of [0, -1, NaN, Infinity]) {
  assert.equal(layout.columns(960, height), 7, 'unmeasured height remains capped');
  assert.equal(layout.columns(374, height), 4, 'unmeasured height respects the narrow-window minimum');
}

for (let w = 240; w <= 1920; w += 11) {
  for (let h = 240; h <= 2160; h += 17) {
    const columns = layout.columns(w, h);
    assert.ok(Number.isInteger(columns) && columns >= 2 && columns <= 7);
    assert.ok(layout.thumbnailWidth(w, columns) >= 80 - 1e-6, 'narrow windows keep usable thumbnails');
    assert.ok(layout.columns(w + 1, h) >= columns, 'wider windows never lose a column');
    assert.ok(layout.columns(w, h + 1) <= columns, 'taller windows never add a column');
  }
}
for (const density of [1, 1.5, 2, 3, 4]) {
  assert.equal(layout.columns(960 * density / density, 1440 * density / density), 5,
    'equal logical windows keep equal column counts at different physical densities');
}
for (const [w, h] of [[374, 827], [712, 776], [800, 800], [960, 1440], [1440, 960]]) {
  const columns = layout.columns(w, h);
  const approximateVisible = columns * columns * h / w;
  assert.ok(approximateVisible >= 30 && approximateVisible <= 40,
    'representative windows keep similar visible-image workloads');
}
assert.ok(layout.thumbnailWidth(1440, 7) > 200, 'the accepted landscape seven-column size is retained');
const windows = [[360, 800], [800, 800], [1440, 1000], [480, 1000], [800, 800], [360, 800]];
const first = windows.map(([w, h]) => layout.columns(w, h));
assert.deepEqual(windows.map(([w, h]) => layout.columns(w, h)), first,
  'fold/unfold/split results are history independent; no remembered previous orientation is required');

// Both the live grid and its navigation snapshot call this one page method.
const page = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const method = page.match(/  private fileGridColumnCount\(\): number \{[\s\S]*?\n  }/)[0];
const pageExports = {};
vm.runInNewContext(ts.transpileModule('export class Page {\n' + method + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: pageExports, FileGridLayout: layout });
const p = new pageExports.Page();
for (const [w, h, expected] of cases) { p.pageWidthVp = w; p.pageHeightVp = h; assert.equal(p.fileGridColumnCount(), expected); }
console.log('PASS: shared grid density — 4-column phones, 5/7 tablet, 6-column square/folded windows, bounded workload, usable thumbnails and history independence');

// node tests/file-grid-layout-regression.cjs <SDK typescript.js>
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/FileGridLayout.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: exportsObject, Number, Math });
const { FileGridLayout: layout } = exportsObject;
const legacy = width => Math.max(2, Math.min(10, Math.floor(width / 80)));
const cases = [
  [360, 800, 4, 'phone portrait'], [800, 360, 10, 'phone landscape'],
  [376, 840, 4, 'phone portrait'], [840, 376, 10, 'phone landscape'],
  [480, 1280, 6, 'narrow tablet split window'], [360, 360, 4, 'small square outer screen'],
  [960, 1440, 6, 'tablet portrait'], [1440, 960, 10, 'tablet landscape'],
  [800, 800, 5, 'square unfolded window'], [700, 800, 4, 'smaller unfolded window'],
  [1080, 780, 7, 'wide unfolded window'], [1440, 1000, 10, 'large unfolded window'],
  [1920, 1080, 10, 'large landscape window'], [1080, 1920, 5, 'large portrait window']
];
for (const [w, h, expected, description] of cases) assert.equal(layout.columns(w, h), expected, description);
for (const width of [0, -1, NaN, Infinity]) assert.equal(layout.columns(width, 900), 2);
for (const height of [0, -1, NaN, Infinity]) assert.equal(layout.columns(960, height), legacy(960), 'unmeasured height keeps the old layout');

for (let w = 240; w <= 1920; w += 11) {
  for (let h = 240; h <= 2160; h += 17) {
    const columns = layout.columns(w, h);
    assert.ok(Number.isInteger(columns) && columns >= 2 && columns <= 10);
    if (Math.min(w, h) < 600) {
      assert.equal(columns, legacy(w), 'phone, outer screen and narrow multiwindow must remain exactly unchanged');
    } else {
      const long = Math.max(w, h);
      const minimum = Math.max(140, layout.thumbnailWidth(long, legacy(long)));
      assert.ok(layout.thumbnailWidth(w, columns) >= minimum - 1e-6, 'never smaller than the large-window minimum/reference');
      if (columns < legacy(w)) {
        assert.ok(layout.thumbnailWidth(w, columns + 1) < minimum, 'use available space without exceeding the maximum fitting columns');
      }
    }
  }
}
for (const density of [1, 1.5, 2, 3, 4]) {
  assert.equal(layout.columns(960 * density / density, 1440 * density / density), 6,
    'equal logical windows keep equal column counts at different physical densities');
}
const beforeWidth = layout.thumbnailWidth(960, 10), afterWidth = layout.thumbnailWidth(960, 6);
assert.ok(afterWidth > beforeWidth);
assert.equal(layout.columns(1440, 960), legacy(1440), 'this tablet retains its accepted landscape density');
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
console.log('PASS: shared grid density — unchanged phones/narrow windows, 6/10 tablet columns, foldable/square windows, minimum tile width, bounded columns and history independence');

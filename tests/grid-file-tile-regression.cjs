// Run after assembleHap: node tests/grid-file-tile-regression.cjs <SDK typescript.js>
// Replay the generated native tree, checking that names cannot add an outer
// row and that media origins still belong to the artwork rather than the card.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const file = 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/components/FileGridCell.ts';
const source = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
const cell = source.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'FileGridCell');
const render = cell.members.find(n => n.name?.text === 'initialRender');
const layoutModule = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/ui/FileGridLayout.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: layoutModule });
const { FileGridLayout } = layoutModule;
let stack, nodes;
function native(type) {
  let leaf;
  return new Proxy({}, { get: (_, key) => {
    if (key === 'create') return value => {
      const node = { type, value, parent: stack.at(-1) };
      nodes.push(node);
      if (type === 'Image') leaf = node;
      else stack.push(node);
    };
    if (key === 'pop') return () => stack.pop();
    return (...args) => { (type === 'Image' ? leaf : stack.at(-1))[key] = args[0]; };
  } });
}
const gesture = new Proxy({}, { get: () => () => {} });
class View {
  observeComponentCreation2(callback) { callback(1, true); }
  ifElseBranchUpdateFunction(_branch, callback) { callback(); }
}
const exportsObject = {};
vm.runInNewContext(ts.transpileModule('export class Tile extends View {' + render.getText(source) + '}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exportsObject, View, Stack: native('Stack'), Column: native('Column'),
  Row: native('Row'), Text: native('Text'), Image: native('Image'),
  If: { create() {}, pop() {}, canRetake: () => false }, Gesture: gesture,
  GestureGroup: gesture, LongPressGesture: gesture, PanGesture: gesture,
  GesturePriority: {}, GestureMode: {}, PanDirection: {}, Alignment: { Center: 'center', BottomEnd: 'bottom-end' },
  TextAlign: { Center: 'center' }, TextOverflow: { Ellipsis: 'ellipsis' }, FileGridLayout,
  ImageFit: { Contain: 'contain' }, HitTestMode: { None: 'none' }, $r: value => value,
  ObservedObject: { GetRawObject: value => value } });
for (const tileWidth of [80, 100, 205, 320]) {
for (const kind of ['photo', 'video', 'file']) {
  const showName = kind === 'file';
  nodes = []; stack = [];
  let contentParent, videoIndicators = 0;
  const h = new exportsObject.Tile();
  Object.assign(h, { showName, tileWidth, selectionMode: false, topInset: 0, entry: { name: 'a-long-filename' },
    thumbnailId: 'artwork', tileId: 'tile', events: { isVideo: () => kind === 'video' },
    content() { contentParent = stack.at(-1); }, videoIndicator() { videoIndicators++; } });
  h.initialRender();
  assert.equal(stack.length, 0);
  const square = nodes.find(n => n.aspectRatio === 1);
  assert.ok(square, 'every tile has the same square frame');
  const text = nodes.filter(n => n.type === 'Text');
  assert.equal(text.length, showName ? 1 : 0);
  assert.equal(contentParent.id, 'artwork');
  if (showName) {
    assert.equal(square.id, 'tile');
    const iconSize = FileGridLayout.fileIconSize(tileWidth);
    assert.deepEqual([contentParent.width, contentParent.height], [iconSize, iconSize]);
    let ancestor = text[0];
    while (ancestor && ancestor !== square) ancestor = ancestor.parent;
    assert.equal(ancestor, square, 'filename stays inside the square rather than increasing row height');
    assert.equal(text[0].maxLines, 2); assert.equal(text[0].textOverflow.overflow, 'ellipsis');
    assert.equal(text[0].fontSize, FileGridLayout.fileLabelFontSize(tileWidth));
    const group = contentParent.parent;
    assert.ok(iconSize + group.value.space + text[0].height <= tileWidth - 2 * FileGridLayout.cellPadding,
      'icon, spacing and two label lines fit inside the square even in narrow windows');
    assert.ok(iconSize + group.padding.left + group.padding.right <= tileWidth - 2 * FileGridLayout.cellPadding);
  } else {
    assert.equal(contentParent, square, 'photos/videos retain the full-square shared-element source');
  }
  assert.equal(videoIndicators, kind === 'video' ? 1 : 0, 'video progress remains on the outer card exactly once');
  const badge = nodes.filter(n => n.type === 'Image');
  assert.equal(badge.length, kind === 'video' ? 1 : 0);
  if (kind === 'video') {
    assert.ok(badge[0].position.left > 0 && badge[0].position.bottom > 0);
    assert.equal(badge[0].position.right, undefined, 'video badge stays at the lower left');
    assert.equal(badge[0].draggable, false);
  }
}
}
assert.ok(FileGridLayout.fileIconSize(205) > FileGridLayout.fileIconSize(100), 'tablet icons grow with the tile');
assert.ok(FileGridLayout.fileIconSize(1000) <= 88, 'large windows cannot stretch file icons without a bound');
console.log('PASS compiled grid tile: photo/video cover preservation, adaptive file layout at 4 widths, contained filenames and artwork origins');

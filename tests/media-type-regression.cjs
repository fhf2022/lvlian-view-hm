const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const root = 'entry/src/main/ets/';
function compile(source, bindings = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports, ...bindings });
  return exports;
}
const { MediaType } = compile(fs.readFileSync(root + 'model/MediaType.ets', 'utf8'));
const { DirectoryTimelinePolicy, DirectoryQuery } = compile(fs.readFileSync(root + 'model/DirectoryTimeline.ets', 'utf8'), {
  require: key => { assert.equal(key, './MediaType'); return { MediaType }; }
});
const { MediaPreviewManager } = compile(fs.readFileSync(root + 'media/MediaPreviewManager.ets', 'utf8'), {
  require: key => key === '../model/MediaType' ? { MediaType } : {}
});
const source = fs.readFileSync(root + 'pages/Index.ets', 'utf8');
function method(name) {
  const start = source.search(new RegExp('^  private ' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return source.slice(start, start + end + 1);
}
const { Page } = compile('export class Page {\n' + ['isImage', 'isAudio', 'isVideo', 'fileExtension'].map(method).join('\n') + '\n}', { MediaType });
const page = new Page(), preview = new MediaPreviewManager();
const images = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff'];
const videos = ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'ts', 'mpeg', 'mpg', 'm2ts', 'mts', 'wmv', 'flv', 'f4v', 'rmvb', 'asf'];
const audio = ['mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg', 'amr'];
const localVideos = ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'ts'];
const entry = (name, mimeType = '', isDirectory = false) => ({ name, mimeType, isDirectory, path: '/temp/' + name, size: 10, modifiedTime: 1 });
function included(e, mediaFilter) {
  const query = new DirectoryQuery(); query.mediaFilter = mediaFilter;
  return DirectoryTimelinePolicy.query([e], query).length === 1;
}
for (const [kind, extensions] of [['image', images], ['video', videos], ['audio', audio]]) {
  for (const ext of extensions) {
    for (const name of ['sample.' + ext, 'sample.' + ext.toUpperCase()]) {
      const e = entry(name);
      assert.equal(MediaType.kindForExtension(MediaType.extension(name)), kind);
      assert.equal(page.isImage(e), kind === 'image');
      assert.equal(page.isVideo(e), kind === 'video');
      assert.equal(page.isAudio(e), kind === 'audio');
      assert.equal(included(e, 'images'), kind === 'image');
      assert.equal(included(e, 'videos'), kind === 'video');
      assert.equal(included(e, 'media'), kind !== 'audio');
      assert.equal(preview.kind(e), kind === 'video' && !localVideos.includes(ext) ? '' : kind);
    }
  }
}
for (const kind of ['image', 'video', 'audio']) {
  const e = entry('unknown.bin', '  ' + kind.toUpperCase() + '/EXAMPLE  ');
  assert.equal(page['is' + kind[0].toUpperCase() + kind.slice(1)](e), true);
  assert.equal(included(e, 'images'), kind === 'image');
  assert.equal(included(e, 'videos'), kind === 'video');
  assert.equal(preview.kind(e), '', 'classification by MIME must not expand local decoder capability');
}
for (const name of ['sample.jpg', 'sample.mp4', 'sample.mp3']) {
  const dir = entry(name, 'video/mp4', true);
  assert.equal(page.isImage(dir), false); assert.equal(page.isVideo(dir), false); assert.equal(page.isAudio(dir), false);
  assert.equal(preview.kind(dir), '', 'a directory named after a media file cannot be decoded');
  assert.equal(included(dir, 'videos'), true, 'media filtering retains directory navigation');
}
for (const name of ['', '.jpg', 'file.', 'README', 'file.pdf', 'file.mp4.tmp']) {
  const e = entry(name);
  assert.equal(MediaType.kindForExtension(MediaType.extension(name)), ''); assert.equal(preview.kind(e), '');
  assert.equal(page.isImage(e) || page.isAudio(e) || page.isVideo(e), false);
}
// Keep the existing independent MIME/extension recognition. Opening precedence
// still belongs to the existing image -> audio -> video entry methods.
const ambiguous = entry('sample.gif', 'video/mp4');
assert.equal(page.isImage(ambiguous), true); assert.equal(page.isVideo(ambiguous), true);
assert.equal(MediaType.kind(ambiguous), 'image', 'opening precedence keeps images first');
assert.equal(MediaType.kind(entry('sample.mp4', 'audio/mpeg')), 'audio', 'audio remains ahead of video');
assert.equal(MediaType.kind(entry('unknown.bin')), '');
console.log('PASS media types: main UI and timeline agree for every supported extension, uppercase/MIME/folder boundaries; missing-MIME videos retained; local fallback decoder allowlist unchanged');

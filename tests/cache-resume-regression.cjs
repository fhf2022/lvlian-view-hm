// Run: node tests/cache-resume-regression.cjs <typescript.js>
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const path = require('node:path'), ts = require(process.argv[2]);
const files = new Map(), fds = new Map(), modules = new Map(), requests = [], pins = new Map();
let serial = 0, scenario, metadataWrites = 0;
const io = {
  OpenMode: { READ_ONLY: 1, WRITE_ONLY: 2, CREATE: 4, APPEND: 8, TRUNC: 16 },
  statSync: p => ({ size: files.get(p).length }), readTextSync: p => files.get(p).toString(),
  openSync(p, mode) {
    if (mode & 16) files.set(p, Buffer.alloc(0));
    if (!files.has(p)) { if (!(mode & 4)) throw Error('missing'); files.set(p, Buffer.alloc(0)); }
    const fd = ++serial; fds.set(fd, { p, at: mode & 8 ? files.get(p).length : 0 }); return { fd };
  },
  closeSync(fd) { assert.ok(fds.delete(fd)); },
  writeSync(fd, bytes) {
    const f = fds.get(fd), b = Buffer.from(bytes), old = files.get(f.p);
    const out = Buffer.alloc(Math.max(old.length, f.at + b.length)); old.copy(out); b.copy(out, f.at);
    files.set(f.p, out); f.at += b.length;
    if (f.p.endsWith('.resume.json')) metadataWrites++;
    return b.length;
  },
  renameSync(a, b) { assert.ok(files.has(a)); files.set(b, files.get(a)); files.delete(a); },
  unlinkSync: p => files.delete(p)
};
modules.set('@kit.CoreFileKit', { fileIo: io }); modules.set('@kit.ArkTS', { util: {} });
modules.set('download/StorageBudget', { StorageBudget: {
  pin: p => pins.set(p, (pins.get(p) || 0) + 1), unpin: p => pins.set(p, pins.get(p) - 1), admit() {}, sync() {}
} });
modules.set('download/CacheManager', { CacheManager: {
  cachePath: (d, n, key) => d + '/' + key + '-' + n, hash: s => Buffer.from(s).toString('hex'),
  exists: p => files.has(p), prepareForIncoming: async () => {}, enforceLimit: async () => {}
} });
modules.set('core/network/NasConnection', { NasConnection: { shared: () => ({ begin: () => 1, response() {}, failed() {} }) } });
modules.set('@kit.NetworkKit', { http: { RequestMethod: { GET: 0 }, createHttp() {
  const h = {}; let rejectRequest;
  return { on: (k, f) => h[k] = f, off: k => delete h[k], destroy: () => rejectRequest?.(Error('cancelled')),
    requestInStream(url, options) { requests.push(options); return new Promise((resolve, reject) => {
      rejectRequest = reject; queueMicrotask(() => { try { scenario(h, resolve); } catch (e) { reject(e); } });
    }); }
  };
} } });
function load(name) {
  if (modules.has(name)) return modules.get(name);
  const exports = {}; modules.set(name, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/' + name + '.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, { exports, console, ArrayBuffer, Uint8Array,
    require: key => load(key.startsWith('@') ? key : path.posix.normalize(path.posix.join(path.posix.dirname(name), key))) });
  return exports;
}
const { DownloadManager } = load('download/DownloadManager');
const { HttpTransport } = load('core/network/HttpTransport');
const { DownloadCancellation } = load('core/network/DownloadCancellation');
const date = 'Fri, 23 Oct 2026 07:00:14 GMT', modified = 'Sat, 09 Nov 2024 11:36:28 GMT';
const target = '/cache/accountA-photo', part = target + '.part', meta = part + '.resume.json';
const descriptor = { url: 'https://nas/image', headers: {}, fileName: 'photo', size: 6, etag: '', checksum: '' };
const chunk = (h, s) => h.dataReceive(Uint8Array.from(Buffer.from(s)).buffer);
const headers = (h, offset = 0, validator = modified, extra = {}) => h.headersReceive({
  'status-line': offset ? 'HTTP/1.1 206 Partial Content' : 'HTTP/1.1 200 OK',
  'content-length': String(6 - offset), ...(offset ? { 'content-range': `bytes ${offset}-5/6` } : {}),
  date, ...(validator ? { 'last-modified': validator } : {}), ...extra
});
const request = (signal, key = 'accountA') => new DownloadManager(new HttpTransport()).download(descriptor, '/cache', 1e6, key, undefined, undefined, signal);
const finish = (h, resolve, text, offset = 0, validator = modified) => { headers(h, offset, validator); chunk(h, text); h.dataEnd(); resolve(offset ? 206 : 200); };
function clean() { assert.equal(fds.size, 0); assert.ok([...pins.values()].every(n => n === 0)); }
function reset() { clean(); files.clear(); requests.length = 0; metadataWrites = 0; }
(async () => {
  const first = new DownloadCancellation();
  scenario = h => { headers(h); chunk(h, 'A'); chunk(h, 'BC'); first.cancel(); };
  await assert.rejects(request(first));
  assert.equal(files.get(part).toString(), 'ABC'); assert.equal(JSON.parse(files.get(meta)).validator, modified);
  assert.equal(metadataWrites, 1, 'metadata is not written for each chunk');
  const second = new DownloadCancellation();
  scenario = h => { headers(h, 3); chunk(h, 'D'); second.cancel(); };
  await assert.rejects(request(second)); assert.equal(requests.at(-1).header.Range, 'bytes=3-');
  assert.equal(requests.at(-1).header['If-Range'], modified); assert.equal(files.get(part).toString(), 'ABCD');
  scenario = (h, resolve) => finish(h, resolve, 'EF', 4);
  await request(); assert.equal(requests.at(-1).header.Range, 'bytes=4-');
  assert.equal(files.get(target).toString(), 'ABCDEF'); assert.ok(!files.has(meta)); clean();

  // Unknown/weak/corrupt validators never authorize appending old bytes.
  for (const kind of ['missing', 'weak', 'corrupt']) {
    reset(); const signal = new DownloadCancellation();
    scenario = h => { headers(h, 0, kind === 'missing' ? '' : modified, kind === 'weak' ? { etag: 'W/"old"' } : {}); chunk(h, 'OLD'); signal.cancel(); };
    await assert.rejects(request(signal));
    if (kind === 'corrupt') files.set(meta, Buffer.from('{broken'));
    scenario = (h, resolve) => finish(h, resolve, 'NEWDAT');
    await request(); assert.equal(requests.at(-1).header.Range, undefined, kind);
    assert.equal(files.get(target).toString(), 'NEWDAT'); clean();
  }

  reset(); const signal = new DownloadCancellation();
  scenario = h => { headers(h); chunk(h, 'OLD'); signal.cancel(); }; await assert.rejects(request(signal));
  let attempts = 0;
  scenario = (h, resolve) => {
    if (++attempts === 1) { headers(h, 3, 'Sun, 10 Nov 2024 11:36:28 GMT'); chunk(h, 'BAD'); h.dataEnd(); resolve(206); }
    else finish(h, resolve, 'NEWNEW');
  };
  await request(); assert.equal(attempts, 2); assert.equal(files.get(target).toString(), 'NEWNEW', 'changed source never mixes prefixes'); clean();

  reset(); const abandoned = new DownloadCancellation();
  scenario = h => { headers(h); chunk(h, 'OLD'); abandoned.cancel(); }; await assert.rejects(request(abandoned));
  scenario = (h, resolve) => finish(h, resolve, 'OTHER!'); await request(undefined, 'accountB');
  assert.equal(requests.at(-1).header.Range, undefined); assert.equal(files.get(part).toString(), 'OLD'); clean();
  files.delete(part); scenario = (h, resolve) => finish(h, resolve, 'FRESH!'); await request();
  assert.equal(requests.at(-1).header.Range, undefined, 'reclaimed partial restarts safely'); clean();

  reset(); descriptor.etag = '"version-A"';
  const strongPart = target + '.' + Buffer.from(descriptor.etag).toString('hex') + '.part';
  files.set(strongPart, Buffer.from('ABC'));
  scenario = (h, resolve) => {
    headers(h, 3, '', { etag: descriptor.etag }); chunk(h, 'DEF'); h.dataEnd(); resolve(206);
  };
  await request(); assert.equal(requests.at(-1).header.Range, 'bytes=3-', 'legacy strong-ETag partial still resumes');
  assert.equal(requests.at(-1).header['If-Range'], descriptor.etag);
  assert.equal(files.get(target).toString(), 'ABCDEF'); clean();
  console.log('PASS cache originals: cancel/swipe/reopen across managers, repeated resume, Last-Modified, bounded metadata writes, missing/weak/corrupt validators, source replacement, account isolation, reclaimed partial, cleanup');
})().catch(e => { console.error(e); process.exitCode = 1; });

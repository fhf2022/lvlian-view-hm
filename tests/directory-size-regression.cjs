const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2]);
let serial = 0;
const timers = new Map();
function compile(source, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports, console, ...globals });
  return exports;
}
const { DirectorySizeQuery: Query } = compile(fs.readFileSync('entry/src/main/ets/ugreen/DirectorySizeQuery.ets', 'utf8'), {
  setTimeout(fn, delay) { const id = ++serial; timers.set(id, { fn, delay }); return id; },
  clearTimeout(id) { timers.delete(id); }
});
const tick = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
async function advance() {
  assert.equal(timers.size, 1, 'one timer per open dialog, no overlapping polls');
  const [id, timer] = [...timers][0];
  assert.equal(timer.delay, 700);
  timers.delete(id);
  timer.fn();
  await tick();
}
function method(source, name) {
  const start = source.search(new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder|async |[a-zA-Z]+\()/m);
  assert.ok(end >= 0, name + ' end');
  return source.slice(start, start + end + 1);
}
(async () => {
  let calls = 0;
  const results = [], cancelled = [];
  const query = new Query(async () => ++calls < 3
    ? { status: 0, calculate_id: 7, size: 40 } : { status: 1, calculate_id: 7, size: 123456 },
    async id => { cancelled.push(id); }, () => true);
  assert.equal(calls, 0, 'constructing a query never starts network traffic');
  query.start(size => results.push(size));
  query.start(() => assert.fail('duplicate start'));
  await tick();
  assert.equal(calls, 1); assert.equal(results.length, 0, 'partial size is not shown as a final total');
  await advance(); await advance();
  assert.deepEqual(results, [123456]); assert.equal(timers.size, 0);
  query.stop(); assert.deepEqual(cancelled, [], 'completed calculation needs no delete request');
  for (const size of [0, 1234567890123]) {
    const values = [];
    new Query(async () => ({ status: 1, size }), async () => {}, () => true).start(value => values.push(value));
    await tick(); assert.deepEqual(values, [size], 'zero and large folders keep their byte counts');
  }
  // Stop before the initial HTTP response reveals its calculation ID.
  let release;
  const late = new Query(() => new Promise(resolve => { release = resolve; }), async id => cancelled.push(id), () => true);
  late.start(() => assert.fail('dismissed dialog updated')); late.stop();
  release({ status: 0, calculate_id: 'late-id' }); await tick();
  assert.deepEqual(cancelled, ['late-id']); assert.equal(timers.size, 0);
  // Stop while the next poll is in flight, after an ID is already known.
  calls = 0;
  const inFlight = new Query(() => ++calls === 1 ? Promise.resolve({ status: 0, calculate_id: 9 })
    : new Promise(resolve => { release = resolve; }), async id => cancelled.push(id), () => true);
  inFlight.start(() => assert.fail('closed poll updated')); await tick(); await advance();
  inFlight.stop(); inFlight.stop(); release({ status: 0, calculate_id: 9 }); await tick();
  assert.equal(cancelled.filter(id => id === 9).length, 1, 'cancel is idempotent even with a late response');
  assert.equal(timers.size, 0);
  for (const response of [() => Promise.reject(Error('offline')), async () => ({ status: 2 }),
    async () => ({ status: 1 }), async () => ({ status: 1, size: -1 }), async () => ({ status: 1, size: NaN }),
    async () => ({ status: 999 })]) {
    const errors = [];
    new Query(response, async () => {}, () => true).start(value => errors.push(value));
    await tick(); assert.deepEqual(errors, [null]); assert.equal(timers.size, 0, 'errors never start an infinite retry loop');
  }
  let valid = true;
  const changed = new Query(() => new Promise(resolve => { release = resolve; }), async id => cancelled.push(id), () => valid);
  const stale = []; changed.start(size => stale.push(size)); valid = false;
  release({ status: 0, calculate_id: 'old-account' }); await tick();
  assert.deepEqual(stale, [null]); assert.ok(cancelled.includes('old-account')); assert.equal(timers.size, 0);

  const client = fs.readFileSync('entry/src/main/ets/ugreen/UgreenRemoteClient.ets', 'utf8');
  const { Client } = compile('export class Client {\n' + method(client, 'createDirectorySizeQuery') + '\n}', {
    DirectorySizeQuery: Query, http: { RequestMethod: { GET: 'GET', POST: 'POST' } }
  });
  const { UgreenEndpoints: Endpoints } = compile(fs.readFileSync('entry/src/main/ets/ugreen/UgreenEndpoints.ets', 'utf8'));
  const c = new Client(), oldEndpoint = new Endpoints('https://old-nas.invalid');
  const oldSession = {}; let session = oldSession; const requests = [];
  Object.assign(c, { endpoints: oldEndpoint, sessionStore: { get: () => session },
    requireEndpoints: () => c.endpoints, authHeaders: async () => ({ authorization: 'old-test-auth' }),
    withHeaders: (headers, name, value) => ({ ...headers, [name]: value }), successData: body => body.data,
    transport: { requestJson: async (url, method, body, headers) => {
      requests.push({ url, method, body, headers });
      return { body: { data: { status: 0, calculate_id: 42 } } };
    } }
  });
  const bound = c.createDirectorySizeQuery({ path: '/folder/a & b', intranetShareId: 3 });
  bound.start(() => assert.fail('closed query callback')); await tick();
  const url = new URL(requests[0].url);
  assert.equal(url.pathname, '/ugreen/v2/filemgr/getSizeAndCount');
  assert.equal(url.searchParams.get('path'), '/folder/a & b');
  assert.equal(url.searchParams.get('intranet_share_id'), '3');
  c.endpoints = new Endpoints('https://new-nas.invalid'); session = {};
  bound.stop(); await tick();
  assert.equal(requests.length, 2); assert.equal(requests[1].method, 'POST');
  assert.equal(new URL(requests[1].url).host, 'old-nas.invalid');
  assert.equal(requests[1].headers.authorization, 'old-test-auth');
  assert.equal(requests[1].body.calculate_id, 42, 'cleanup preserves the server ID type and original account');

  // Exercise the component lifecycle without ArkUI rendering.
  const content = fs.readFileSync('entry/src/main/ets/components/EntryDetailsContent.ets', 'utf8');
  const model = content.slice(content.indexOf('export class EntryDetailsData'), content.indexOf('/** Shared'));
  const fields = content.slice(content.indexOf('  @Prop title:'), content.indexOf('  build()'))
    .replace(/@(Prop|State) /g, '');
  const { Content, EntryDetailsData: Data } = compile(model + '\nexport class Content {\n' + fields + '\n}');
  const view = new Content(); view.data = Object.assign(new Data(), { type: 'folder', path: '/folder', items: '2 items' });
  view.createSizeQuery = () => new Query(async () => ({ status: 1, size: 2048 }), async () => {}, () => true);
  view.formatSize = size => size + ' bytes'; view.aboutToAppear(); await tick();
  assert.ok(view.message().includes('2048 bytes')); view.aboutToDisappear();
  const file = new Content(); file.data = Object.assign(new Data(), { size: '12 MB', type: 'mp4' });
  file.aboutToAppear(); assert.ok(file.message().includes('12 MB')); assert.equal(file.sizeQuery, null, 'ordinary files never query folder statistics');
  const closed = new Content();
  closed.createSizeQuery = () => new Query(() => new Promise(resolve => { release = resolve; }), async () => {}, () => true);
  closed.aboutToAppear(); closed.aboutToDisappear(); release({ status: 1, size: 99 }); await tick();
  assert.equal(closed.directorySize, '计算中', 'a late result cannot mutate a removed component');
  assert.equal(timers.size, 0);
  // Use the page's real dialog formatter: its generic formatter treats zero as unknown.
  const pageSource = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
  let dialogProps;
  const { Page } = compile('export class Page {\n' + method(pageSource, 'EntryDetailsDialogContent') + '\n}', {
    EntryDetailsContent: props => { dialogProps = props; }
  });
  const page = new Page();
  Object.assign(page, { pageHeightVp: 800, topSafeInset: () => 0, bottomSafeInset: () => 0,
    formatSize: value => value > 0 ? value + ' bytes' : 'unknown' });
  page.EntryDetailsDialogContent('empty folder', new Data(), () => query, () => {});
  assert.equal(dialogProps.formatSize(0), '0 B', 'a confirmed empty folder must not inherit the generic unknown-size display');
  assert.equal(dialogProps.formatSize(2048), '2048 bytes');
  console.log('PASS directory size: lazy sequential web protocol, zero/large totals, cancellation races, session isolation, failures and details component lifecycle');
})().catch(error => { console.error(error); process.exitCode = 1; });

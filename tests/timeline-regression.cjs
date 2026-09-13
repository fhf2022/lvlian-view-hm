// Run: node tests/timeline-regression.cjs <path-to-typescript.js>
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');

const exportsObject = {};
const source = fs.readFileSync('entry/src/main/ets/model/DirectoryTimeline.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
class FileEntry {
  constructor(name, modifiedTime, isDirectory = false) {
    this.name = name;
    this.path = '/' + name;
    this.modifiedTime = modifiedTime;
    this.createdTime = modifiedTime;
    this.isDirectory = isDirectory;
    this.mimeType = '';
    this.size = 1;
    this.childCount = 0;
    this.rootType = 3;
    this.intranetShareId = 0;
    this.thumbnailUrl = '';
    this.coverUrl = '';
    this.etag = '';
    this.checksum = '';
  }
}
vm.runInNewContext(compiled, {
  exports: exportsObject,
  require: key => {
    assert.equal(key, './FileEntry');
    return { FileEntry };
  },
  Date,
  Map,
  Number,
  Math,
  JSON
});

const {
  DirectoryQuery,
  DirectoryTimelinePolicy: policy
} = exportsObject;
const day = policy.DAY_MS;
const start = new Date(2025, 0, 1).getTime();
const entries = [];
for (let index = 0; index < 160; index++) {
  entries.push(new FileEntry(`image-${index}.jpg`, start + (index % 40) * day));
}
entries.push(new FileEntry('movie.mp4', start + 100 * day));
entries.push(new FileEntry('folder.jpg', start + 100 * day, true));

const eligible = policy.build(entries, true);
assert.equal(eligible.directImageCount, 160);
assert.equal(eligible.buckets.length, 40);
assert.equal(eligible.eligible(), true);
assert.equal(policy.build(entries.slice(0, 79), true).eligible(), false);
assert.equal(policy.build(entries.slice(0, 80), true)
  .eligible(policy.minimumImageCount(10)), true);
assert.equal(policy.build(entries.slice(0, 80), true)
  .eligible(policy.minimumImageCount(14)), false);
assert.equal(policy.build(entries, false).eligible(), false);
const shortSpan = entries.slice(0, 160).map((entry, index) =>
  new FileEntry(entry.name, start + (index % 29) * day));
assert.equal(policy.build(shortSpan, true).eligible(), false);

const query = new DirectoryQuery();
query.sortKey = 'time';
query.ascending = false;
const sorted = policy.query(entries, query);
assert.equal(sorted[0].isDirectory, true);
assert.ok(sorted[1].modifiedTime >= sorted[2].modifiedTime);
assert.equal(policy.closestDay(eligible, start + 20.4 * day),
  policy.localDayStart(start + 20 * day));
const january = new Date(2025, 0, 15).getTime();
assert.equal(policy.dayInPeriod(eligible, january, 'month', true),
  policy.localDayStart(start));
assert.equal(policy.dayInPeriod(eligible, january, 'month', false),
  new Date(2025, 0, 31).getTime());
assert.equal(policy.dayInPeriod(eligible, january, 'year', false),
  policy.localDayStart(start + 39 * day));

const signature = policy.contentSignature(entries);
assert.equal(policy.contentSignature(entries.slice().reverse()), signature);
const changedEntries = entries.slice();
changedEntries[0] = new FileEntry(entries[0].name, entries[0].modifiedTime + day);
assert.notEqual(policy.contentSignature(changedEntries), signature);

console.log('PASS: complete-index gate, adaptive thresholds, signatures, global sort and period jumps');

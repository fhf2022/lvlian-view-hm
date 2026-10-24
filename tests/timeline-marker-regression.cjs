const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/components/FisheyeTimeline.ets', 'utf8');
const marker = source.slice(source.indexOf('class TimelineMarker {'), source.indexOf('@Component'));
function method(name) {
  const start = source.search(new RegExp('^  private ' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = source.slice(start + 1).search(/^  (?:private |@Builder|build\()/m);
  return source.slice(start, start + end + 1);
}
const names = ['updateMarkerNodes', 'addDays', 'addMonths', 'addYears',
  'periodHasImages', 'marker', 'markers'];
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(marker + '\nexport class Harness {\n' +
  names.map(method).join('\n') + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: exportsObject, Date, Math, Number,
  DirectoryTimelinePolicy: { localDayStart(value) {
    const date = new Date(value);
    return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  } }
});
const h = new exportsObject.Harness();
const focus = new Date(2025, 4, 14, 12).getTime();
Object.assign(h, { markerNodes: [], focusTime: focus, heightVp: 400,
  timeline: { buckets: [{ dayStart: new Date(2025, 4, 14).getTime() }] } });
h.updateMarkerNodes();
assert.equal(h.markerNodes.length, 17);
assert.equal(new Set(h.markerNodes.map(item => item.id)).size, 17);
const pool = h.markerNodes.slice();
const byId = id => h.markerNodes.find(item => item.id === id);
assert.equal(byId('d0').label, '5/14');
assert.equal(byId('d-1').label, '13');
assert.equal(byId('d1').label, '15');
assert.equal(byId('mb1').label, '4月');
assert.equal(byId('ma1').label, '6月');
assert.equal(byId('d0').hasImages, true);
const previousY = byId('d1').y;
h.focusTime = new Date(2026, 0, 1, 6).getTime();
h.updateMarkerNodes();
assert.ok(h.markerNodes.every((item, index) => item === pool[index]),
  'crossing date/year boundaries must retain the observed objects bound to child nodes');
assert.equal(byId('d0').label, '1/1');
assert.equal(byId('d-1').label, '31');
assert.equal(byId('d1').label, '2');
assert.equal(byId('mb1').label, '12月');
assert.equal(byId('ma1').label, '2月');
assert.equal(byId('yb1').label, '2025');
assert.equal(byId('ya1').label, '2027');
assert.notEqual(byId('d1').y, previousY, 'stable keys must not freeze marker positions');
assert.equal(byId('d0').hasImages, false, 'calendar availability must refresh with the date');
const oldY = byId('d1').y;
h.heightVp = 600;
h.updateMarkerNodes();
assert.notEqual(byId('d1').y, oldY, 'layout changes update existing markers');
h.timeline = { buckets: [{ dayStart: new Date(2026, 0, 1).getTime() }] };
h.updateMarkerNodes();
assert.equal(byId('d0').hasImages, true, 'directory metadata changes update availability');
assert.ok(h.markerNodes.every((item, index) => item === pool[index]));
console.log('Timeline marker regression passed');

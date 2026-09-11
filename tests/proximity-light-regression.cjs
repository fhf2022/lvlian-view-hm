// Run the production distance/direction calculation without ArkUI rendering.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const exportsObject = {};
const source = fs.readFileSync('entry/src/main/ets/components/ProximityLighting.ets', 'utf8');
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, { exports: exportsObject });
const { ProximityLighting: light, ImportLightState } = exportsObject;
const strength = light.strength;
assert.equal(new ImportLightState().active, false);
// Front, back and tangential surfaces are distinct.
assert.ok(strength(0, 0, 0, -1, 0, -28) > 0.8);
assert.equal(strength(0, 0, 0, 1, 0, -28), 0);
assert.equal(strength(0, 0, 1, 0, 0, -28), 0);
let previous = 1;
for (let distance = 1; distance <= light.RANGE; distance++) {
  const value = strength(0, 0, 0, -1, 0, -distance);
  assert.ok(value >= 0 && value <= previous, `falloff at ${distance}`);
  previous = value;
}
assert.equal(strength(0, 0, 0, -1, 0, -140), 0);
assert.equal(strength(0, 0, 0, -1, 0, -200), 0);
assert.ok(strength(0, 0, 0, -1, 0, -139.99) < 0.000001);
assert.equal(strength(0, 0, 1, 0, 0, 0), 0);
// Window insets/landscape translation must not change the result.
const expected = strength(20, 35, 0, -1, 40, -30);
assert.equal(strength(320, 935, 0, -1, 340, 870), expected);
assert.equal(strength(-20, 35, 0, -1, -40, -30), expected);
assert.equal(strength(35, 20, -1, 0, -30, 40), expected);
console.log('PASS: range, smooth falloff, facing, mirror and window-coordinate invariance');

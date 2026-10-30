const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require(process.argv[2]);
function method(source,name){const a=source.search(new RegExp('^  private '+name+'\\(','m'));assert.ok(a>=0,name);const b=source.slice(a+1).search(/^  (?:private |@Builder)/m);return source.slice(a,a+b+1)}
function load(source,bindings){const exports={};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports,...bindings});return exports}
const page=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
const {Page}=load('export class Page { '+method(page,'videoHeaderTopInset')+' }',{});
for(const density of [1,2,3.5]){
 const p=new Page();p.getUIContext=()=>({px2vp:px=>px/density});
 for(const [status,cutout] of [[0,0],[0,40],[24,40],[48,40],[24,0]]){
  Object.assign(p,{videoLandscape:false,statusBarHeightPx:status*density,displayCutoutTopPx:cutout*density});
  assert.equal(p.videoHeaderTopInset(),Math.max(status,cutout),'portrait uses the larger safe region, not their sum');
  p.videoLandscape=true;assert.equal(p.videoHeaderTopInset(),0,'landscape stays immersive');
 }
 p.videoLandscape=false;p.statusBarHeightPx=0;p.displayCutoutTopPx=40*density;assert.equal(p.videoHeaderTopInset(),40,'returning to portrait with hidden status bar still avoids cutout');
 p.displayCutoutTopPx=0;assert.equal(p.videoHeaderTopInset(),0,'no stale cutout spacing in a window without a cutout');
}
const ability=fs.readFileSync('entry/src/main/ets/entryability/EntryAbility.ets','utf8'),values=new Map();
const types={TYPE_SYSTEM:0,TYPE_CUTOUT:1,TYPE_NAVIGATION_INDICATOR:3};
const {Ability}=load('export class Ability { '+method(ability,'updateAvoidArea')+' }',{window:{AvoidAreaType:types},AppStorage:{setOrCreate:(k,v)=>values.set(k,v)}});
const a=new Ability();a.updateAvoidArea(types.TYPE_SYSTEM,{topRect:{height:24}});a.updateAvoidArea(types.TYPE_NAVIGATION_INDICATOR,{bottomRect:{height:16}});a.updateAvoidArea(types.TYPE_CUTOUT,{topRect:{top:0,height:40}});a.updateAvoidArea(types.TYPE_SYSTEM,{topRect:{height:0}});
assert.equal(values.get('displayCutoutTopPx'),40,'hiding status bar cannot erase the hardware cutout');assert.equal(values.get('statusBarHeightPx'),0);assert.equal(values.get('navigationBarHeightPx'),16);
a.updateAvoidArea(types.TYPE_CUTOUT,{topRect:{top:12,height:40}});assert.equal(values.get('displayCutoutTopPx'),52,'a floating camera hole must clear its bottom edge');
a.updateAvoidArea(types.TYPE_CUTOUT,{topRect:{top:12,height:0}});assert.equal(values.get('displayCutoutTopPx'),0,'rotation updates independently');
console.log('PASS video header inset: portrait cutout with hidden status bar, density conversion, landscape zero, rotation and existing bar state isolation');

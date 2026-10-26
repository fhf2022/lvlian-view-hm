const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require(process.argv[2]);
const source=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
function method(name){const a=source.search(new RegExp('^  private (?:async )?'+name+'(?:<[^>]+>)?\\(','m'));assert.ok(a>=0,name);const b=source.slice(a+1).search(/^  (?:private |@Builder)/m);return source.slice(a,a+b+1)}
class UgreenError extends Error {constructor(kind,status){super('failure');this.kind=kind;this.status=status}}
const UgreenErrorKind={NETWORK:'NETWORK',NAS_UNAVAILABLE:'NAS_UNAVAILABLE',PERMISSION_DENIED:'PERMISSION_DENIED'};let probes=0;
const pull={};vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/media/WaterfallEdgePull.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:pull});
const TouchType={Down:0,Up:1,Move:2,Cancel:3},ScrollSource={DRAG:0,FLING:1,SCROLLER:6};
const ex={};vm.runInNewContext(ts.transpileModule('export class Layout {\n'+['updateWaterfallLayout','waterfallFooterHeight','gateWaterfallScroll','waterfallBoundaryOffset','canPullWaterfallEdge','handleWaterfallTouch','cancelWaterfallPull','requestWaterfallEdge','loadSharedImageOriginal','waterfallNetworkRequest','waterfallWaitingVisible'].map(method).join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:ex,console,UgreenError,UgreenErrorKind,TouchType,ScrollSource,Curve:{EaseOut:0},WaterfallEdgePull:pull.WaterfallEdgePull,NasConnection:{shared:()=>({retryNow:async()=>{probes++;return false}})},setTimeout:fn=>queueMicrotask(fn),WaterfallBatchCoordinator:{SIZE:12,MAX_RESIDENT_GROUPS:4}});
function harness(){const p=new ex.Layout();let count=12,first=0,last=0,offset=0;
const entries=Array.from({length:96},(_,i)=>({path:'/image/'+i,ratio:[.75,1.333,2.7,.4,1.1][i%5]}));
Object.assign(p,{waterfallEntries:entries,waterfallLayoutCount:0,waterfallLayoutWidth:1440,waterfallBatchEpoch:0,waterfallLayoutHeight:0,waterfallGroupTops:new Map(),waterfallGroupBottoms:new Map(),waterfallColumnTails:new Map(),waterfallBlockedEdge:0,waterfallPullOffset:0,waterfallEdgePull:new pull.WaterfallEdgePull(),screen:'files',fileViewMode:'waterfall',getUIContext:()=>({animateTo:(_options,fn)=>fn()}),
waterfallBatches:{first:0,published:()=>entries.slice(0,count),residentFirst:()=>first,residentLast:()=>last,hasNext:()=>true,edge:n=>p.edges.push(n)},
waterfallColumnCount:()=>5,waterfallAspectRatio:e=>e.ratio,fileContentTopInset:()=>115,effectivePageWidth:()=>1440,floatingBarContentInset:()=>88,fileScrollViewport:{height:960},waterfallScroller:{currentOffset:()=>({yOffset:offset}),isAtEnd:()=>false},edges:[]});
return{p,setCount:n=>{count=n},setResident:(a,b)=>{first=a;last=b},setOffset:n=>{offset=n}};}
const footer=source.slice(source.indexOf('  WaterfallEndSpace():'),source.indexOf('  WaterfallLoadingStatus():'));
assert.doesNotMatch(footer,/LoadingProgress|this\.WaterfallLoadingStatus/,'footer is spacing only');assert.equal((source.match(/this\.WaterfallLoadingStatus\(\)/g)||[]).length,1,'exactly one batch indicator owner');
(async()=>{
const h=harness(),p=h.p;p.updateWaterfallLayout(true);const first=Array.from(p.waterfallColumnTails.get(0));
h.setCount(24);p.updateWaterfallLayout();assert.deepEqual(Array.from(p.waterfallColumnTails.get(0)),first,'append leaves earlier columns untouched');
assert.equal(p.waterfallGroupTops.get(1),Math.min(...first),'next group continues shortest column, not a hard row break');
assert.ok(p.waterfallGroupTops.get(1)<p.waterfallGroupBottoms.get(0),'groups visually interleave');
h.setCount(60);p.updateWaterfallLayout();const frozen=Array.from(p.waterfallColumnTails,([i,t])=>[i,Array.from(t)]);
h.setResident(2,4);p.updateWaterfallLayout();assert.deepEqual(Array.from(p.waterfallColumnTails,([i,t])=>[i,Array.from(t)]),frozen,'resource eviction never removes/recomputes later masonry positions');
const fresh=harness();fresh.setCount(60);fresh.p.updateWaterfallLayout(true);assert.deepEqual(Array.from(fresh.p.waterfallColumnTails,([i,t])=>[i,Array.from(t)]),frozen,'incremental append matches one continuous full layout');
assert.equal(harness().p.waterfallFooterHeight(),88,'a single group does not add a whole empty viewport');
const short=harness();short.p.waterfallEntries.forEach(e=>e.ratio=40);short.setCount(36);short.setResident(0,2);short.p.updateWaterfallLayout(true);assert.equal(short.p.waterfallFooterHeight(),88,'three groups do not need a release slot under the four-group policy');short.setCount(48);short.setResident(0,3);short.p.updateWaterfallLayout();assert.ok(short.p.waterfallFooterHeight()>88,'short content gets release space only when all four slots are occupied');
const min=p.waterfallGroupBottoms.get(1)-115;assert.equal(p.waterfallBoundaryOffset(-1),min,'upper boundary must exclude all tails of evicted masonry cells');assert.ok(min>p.waterfallGroupTops.get(2)-115,'interleaved groups cannot use the first resident item top');h.setOffset(min);assert.equal(p.gateWaterfallScroll(-10000,0).offsetRemain,0);assert.equal(p.edges.length,0,'contact alone cannot request an old group');p.gateWaterfallScroll(0,0);assert.equal(p.waterfallBlockedEdge,-1,'zero delta keeps the same waiting ring');
h.setOffset(0);assert.equal(p.gateWaterfallScroll(-20,0).offsetRemain,0,'stale offset never produces motion opposite the finger');
h.setOffset(100000);assert.equal(p.gateWaterfallScroll(2000,4).offsetRemain,0,'programmatic drag selection obeys the same resource gate');
const wait=harness();wait.p.waterfallDataSource={totalCount:()=>12};wait.p.waterfallVisibleEndIndex=11;wait.p.waterfallBatches.waiting=()=>true;assert.equal(wait.p.waterfallWaitingVisible(),true,'waiting last group shows a single stable ring');wait.p.waterfallBlockedEdge=1;wait.p.waterfallBatches.waiting=()=>false;assert.equal(wait.p.waterfallWaitingVisible(),false,'completed directory hides the ring even after an edge callback');
// Exercise the real touch -> boundary -> release chain. Native/inertial deltas
// cannot stand in for finger travel, including the native zero-delta edge.
const touch=(p,type,y,x=400,touches=1)=>p.handleWaterfallTouch({type,touches:Array.from({length:touches},(_,id)=>({id,windowX:x,windowY:y})),changedTouches:[{id:0,windowX:x,windowY:y}]});
const drag=harness(),d=drag.p;d.updateWaterfallLayout(true);drag.setOffset(d.waterfallBoundaryOffset(1));
touch(d,TouchType.Down,400);touch(d,TouchType.Move,350);assert.equal(d.edges.length,0,'holding never loads');touch(d,TouchType.Up,350);assert.equal(d.edges.length,0,'under-threshold release does not load');
touch(d,TouchType.Down,400);touch(d,TouchType.Move,340);assert.equal(d.edges.length,0,'armed but still holding does not load');assert.ok(d.waterfallPullOffset<0);touch(d,TouchType.Up,340);assert.deepEqual(d.edges,[1]);assert.equal(d.waterfallPullOffset,0);touch(d,TouchType.Up,340);assert.equal(d.edges.length,1,'same gesture cannot trigger twice');
touch(d,TouchType.Down,400);touch(d,TouchType.Move,330);touch(d,TouchType.Move,395);touch(d,TouchType.Up,395);assert.equal(d.edges.length,1,'pulling back before release disarms it');
touch(d,TouchType.Down,400);touch(d,TouchType.Move,320);touch(d,TouchType.Cancel,320);touch(d,TouchType.Up,320);assert.equal(d.edges.length,1,'cancel does not load');
touch(d,TouchType.Down,400);touch(d,TouchType.Move,300,400,2);touch(d,TouchType.Move,200);touch(d,TouchType.Up,200);assert.equal(d.edges.length,1,'multi-touch cannot load');
touch(d,TouchType.Down,400);touch(d,TouchType.Move,320,550);touch(d,TouchType.Up,320,550);assert.equal(d.edges.length,1,'horizontal gesture cannot load');
drag.setOffset(0);touch(d,TouchType.Down,800);touch(d,TouchType.Move,600);touch(d,TouchType.Up,600);drag.setOffset(d.waterfallBoundaryOffset(1));for(const source of [1,2,4,6,7])d.gateWaterfallScroll(500,source);assert.equal(d.edges.length,1,'fling, spring, scrollbar and indexed jumps never load');
h.setOffset(min);touch(p,TouchType.Down,400);touch(p,TouchType.Move,460);assert.equal(p.gateWaterfallScroll(10,0).offsetRemain,0,'rebound consumes retreat before native content moves');touch(p,TouchType.Up,460);assert.deepEqual(p.edges,[-1],'reverse uses the same release threshold');
const native=harness();native.p.updateWaterfallLayout(true);native.setOffset(native.p.waterfallBoundaryOffset(1)-8);native.p.waterfallScroller.isAtEnd=()=>true;touch(native.p,TouchType.Down,400);touch(native.p,TouchType.Move,340);touch(native.p,TouchType.Up,340);assert.deepEqual(native.p.edges,[1],'native end is authoritative despite trailing row gap / rounding');
// Viewer and geometry fallback cannot open two writers for the same part file.
const shared=new ex.Layout();let resolve,writers=0;shared.imageOriginalRequests=new Map();shared.originalCacheKey=e=>e.path;
shared.ensureCachedFile=()=>{writers++;return new Promise(r=>resolve=r)};
const a=shared.loadSharedImageOriginal({path:'/a'}),b=shared.loadSharedImageOriginal({path:'/a'});assert.equal(writers,1);resolve('/cache/a');assert.deepEqual(await Promise.all([a,b]),['/cache/a','/cache/a']);assert.equal(shared.imageOriginalRequests.size,0);
let attempts=0;assert.equal(await shared.waterfallNetworkRequest(()=>true,async()=>{if(++attempts===1)throw new UgreenError('NETWORK',0);return 'ready'}),'ready');assert.equal(attempts,2);
for(const status of [206,499]){attempts=0;await assert.rejects(shared.waterfallNetworkRequest(()=>true,async()=>{attempts++;throw new UgreenError('NETWORK',status)}));assert.equal(attempts,1,'version/cancel never replays');}
attempts=0;await assert.rejects(shared.waterfallNetworkRequest(()=>true,async()=>{attempts++;throw new UgreenError('NETWORK',0)}));assert.equal(attempts,2,'transient retry is bounded');
attempts=0;await assert.rejects(shared.waterfallNetworkRequest(()=>true,async()=>{attempts++;throw new UgreenError('NAS_UNAVAILABLE',503)}));assert.equal(attempts,1);assert.equal(probes,1,'unavailable NAS uses existing recovery probe once');
console.log('PASS actual continuous masonry: no group seams, append/eviction geometry stability, bounded footer, both edge gates and one physical original writer');
})().catch(e=>{console.error(e);process.exitCode=1});

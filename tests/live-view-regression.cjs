// Exercise the production lifecycle with delayed system calls and theme changes.
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const state = new Map(), calls = [], timers = new Map();
let now = 1800000000000, timerId = 0, enabled = true, startError = 0, startResult = 0, stopFailures = 0,
 startHook = null, updateHook = null;
let ownedImages = 0, releasedAssets = 0;
const tick = () => new Promise(resolve => setImmediate(resolve));
const kit = {
 CapsuleType: { CAPSULE_TYPE_PROGRESS:3, CAPSULE_TYPE_TEXT:1 },
 LayoutType:{ LAYOUT_TYPE_DEFAULT:-1 }, ExtensionType:{ EXTENSION_TYPE_ICON:4 },
 LifeCycleMode:{ AUTO_STOP_WHEN_APP_TERMINATE:1 },
 async isLiveViewEnabled(){return enabled},
 async startLiveView(value){calls.push({kind:'start',value});if(startHook){const hook=startHook;startHook=null;await hook()}
  if(startError)throw {code:startError,message:'rights unavailable'};return {resultCode:startResult}},
 async updateLiveView(value){calls.push({kind:'update',value});if(updateHook){const hook=updateHook;updateHook=null;await hook()}return {resultCode:0}},
 async stopLiveView(value){calls.push({kind:'stop',value});if(stopFailures>0){stopFailures--;throw {code:401}}return {resultCode:0}}
};
const mocks={
 '@kit.AbilityKit':{wantAgent:{OperationType:{START_ABILITY:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:1},getWantAgent:async()=>({})}},
 '@kit.LiveViewKit':{liveViewManager:kit},'@kit.BasicServicesKit':{},
 './TransferLiveViewAssets':{TransferLiveViewAssets:class {
  async create(context,value){ownedImages++;let released=false;
   return {badge:{kind:'app-ring',percent:value.percent},ring:{kind:'direction-ring',direction:value.direction},
    async release(){assert(!released);released=true;ownedImages--}}}
  async release(){releasedAssets++}
 }}
};
class Clock extends Date {static now(){return now}}
function load(file){const exports={};const code=ts.transpileModule(fs.readFileSync('entry/src/main/ets/transfer/'+file+'.ets','utf8'),
 {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
 vm.runInNewContext(code,{exports,require:name=>{assert(mocks[name],name);return mocks[name]},Date:Clock,console,
 AppStorage:{get:key=>state.get(key),setOrCreate:(key,value)=>state.set(key,value)},
 setTimeout:callback=>{const id=++timerId;timers.set(id,callback);return id},clearTimeout:id=>timers.delete(id)});return exports}
const progress=load('TransferProgress');mocks['./TransferProgress']=progress;
const presentation=load('TransferLiveViewPresentation');mocks['./TransferLiveViewPresentation']=presentation;
const {TransferLiveViewManager:Manager}=load('TransferLiveViewManager');
const context={abilityInfo:{bundleName:'cn.fhf.linkfiles',name:'EntryAbility'}};
const summary=extra=>Object.assign(new progress.TransferSummary(),{bytes:300,doneBytes:126,count:3,done:1,uploads:3,percent:42,knownSize:true},extra);
async function settle(manager){for(let i=0;i<7;i++){await manager.queue;await tick()}}
async function advance(manager){now+=1001;for(const [id,callback] of [...timers]){timers.delete(id);callback()}await settle(manager)}
function defer(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve}}
(async()=>{
 let manager=new Manager();manager.initialize(context);manager.update(summary());await settle(manager);
 let value=calls.at(-1).value;assert.equal(value.event,'PROGRESS');assert.equal(value.lifeCycleMode,1);
 assert.equal(value.liveViewData.primary.layoutData.layoutType,-1);assert.equal(value.liveViewData.primary.extensionData.pic.kind,'direction-ring');
 assert.equal(value.liveViewData.capsule.icon.kind,'app-ring');assert.equal(value.liveViewData.capsule.tailIcon.kind,'direction-ring');
 assert.equal(value.liveViewData.capsule.backgroundColor,'#FFFFFFFF');assert.equal(value.liveViewData.capsule.isContentDisplayed,false);
 assert.equal(value.liveViewData.capsule.content,undefined);assert.equal(value.liveViewData.capsule.progress,42);
 const before=calls.length;for(let i=43;i<=78;i++)manager.update(summary({percent:i}));await settle(manager);
 assert.equal(calls.length,before);await advance(manager);assert.equal(calls.length,before+1);assert.equal(calls.at(-1).value.liveViewData.capsule.progress,78);
 manager.setForeground(false);manager.setDarkTheme(true);await advance(manager);
 assert.equal(calls.at(-1).kind,'update');assert.equal(calls.at(-1).value.liveViewData.capsule.backgroundColor,'#FF000000');
 manager.finish(summary({done:3,percent:100}),'completed');await settle(manager);
 value=calls.at(-1).value;assert.equal(calls.at(-1).kind,'stop');assert.equal(value.liveViewData.capsule.status,-1);
 assert.equal(value.liveViewData.primary.keepTime,30);assert.equal(value.liveViewData.capsule.progress,100);assert.equal(ownedImages,0);
 await manager.destroy();assert.equal(timers.size,0);
 console.log('PASS: compact capsule retains both rings, omits duplicate words, switches white/black, coalesces progress and ends at 100%');

 manager=new Manager();manager.initialize(context);manager.setForeground(false);manager.update(summary());await settle(manager);
 assert(!manager.active);manager.setForeground(true);await settle(manager);assert(manager.active);
 manager.update(summary({knownSize:false,percent:0}));await advance(manager);value=calls.at(-1).value;
 assert.equal(value.liveViewData.capsule.type,1);assert.equal(value.liveViewData.capsule.title,'传输');assert(!value.liveViewData.primary.content[0].text.includes('%'));
 manager.finish(summary(),'paused',[Object.assign(new progress.TransferProgress(),{state:'waiting_server'})]);await settle(manager);
 assert.equal(calls.at(-1).value.liveViewData.primary.keepTime,15);assert.match(calls.at(-1).value.liveViewData.primary.content[0].text,/NAS 离线/);
 manager.update(summary({failed:1}));await settle(manager);manager.finish(summary({failed:1}),'failed');await settle(manager);
 assert.match(calls.at(-1).value.liveViewData.primary.content[0].text,/失败 1/);assert.notEqual(calls.at(-1).value.liveViewData.capsule.progress,100);
 manager.update(summary());await settle(manager);manager.finish(summary(),'cancelled');await settle(manager);
 assert.equal(calls.at(-1).value.liveViewData.primary.keepTime,0);await manager.destroy();
 console.log('PASS: foreground-only creation, unknown size without fake percentages, interrupted/failed/cancelled state and immediate capsule removal');

 manager=new Manager();manager.initialize(context);startError=1003500005;const attempts=calls.filter(c=>c.kind==='start').length;
 manager.update(summary());await settle(manager);manager.update(summary({percent:60}));await advance(manager);
 manager.finish(summary(),'paused');await settle(manager);manager.update(summary());await settle(manager);
 assert.equal(calls.filter(c=>c.kind==='start').length,attempts+1);assert(!manager.active);assert.equal(ownedImages,0);
 startError=0;manager.requestResume();await settle(manager);assert(manager.active,'explicit resume can retry after the service is enabled');
 await manager.destroy();
 console.log('PASS: denied rights never retry on every byte update or leak images');

 manager=new Manager();manager.initialize(context);const delayed=defer();startHook=()=>delayed.promise;
 manager.update(summary());for(let i=0;i<6;i++)await tick();assert.equal(calls.at(-1).kind,'start');
 const destroying=manager.destroy();delayed.resolve();await destroying;await settle(manager);
 assert.equal(calls.at(-1).kind,'stop');assert.equal(calls.at(-1).value.liveViewData.capsule.status,-1);assert.equal(ownedImages,0);
 manager=new Manager();manager.initialize(context);manager.update(summary());await settle(manager);
 const late=defer();updateHook=()=>late.promise;now+=1001;manager.update(summary({percent:64}));for(let i=0;i<6;i++)await tick();
 manager.finish(summary(),'cancelled');late.resolve();await settle(manager);
 assert.equal(calls.at(-1).kind,'stop');assert.equal(calls.at(-1).value.liveViewData.primary.keepTime,0);assert(!manager.active);await manager.destroy();
 assert.equal(ownedImages,0);assert.equal(timers.size,0);assert(releasedAssets>=5);
 console.log('PASS: create/update responses arriving after cancellation or destruction cannot leave a live capsule or retained bitmaps');
 manager=new Manager();manager.initialize(context);startResult=4;manager.update(summary());await settle(manager);
 assert.equal(calls.at(-1).kind,'stop');assert(!manager.active);assert.equal(ownedImages,0);await manager.destroy();startResult=0;
 manager=new Manager();manager.initialize(context);manager.update(summary());await settle(manager);stopFailures=1;
 manager.finish(summary(),'cancelled');await settle(manager);
 assert.equal(calls.at(-1).value.liveViewData.capsule.title,'传输');assert.equal(calls.at(-1).value.liveViewData.capsule.status,-1);
 assert(!manager.active);assert.equal(ownedImages,0);await manager.destroy();
 assert.equal(presentation.presentTransfer(summary({done:0,failed:3}),'failed',false).title,'上传失败');
 console.log('PASS: a partial native result is cleaned up; ending with an invalid optional region retries without images; total failure is labelled correctly');
})().catch(error=>{console.error(error);process.exitCode=1});

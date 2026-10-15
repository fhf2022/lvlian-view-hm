// Runs the production coordinator against system service faults and cancellation races.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript');
const storage=new Map(), events=new Set(),starts=[],stops=[],notifications=[];
let startFailure=false,publishFailure=false,publishHook=null,sequence=10;
let notificationEnabled=true,liveEnabled=true,requestAllowed=true,permissionRequests=0;
const permissionPrefs=new Map();
const system={ContinuousTaskRequest:class{},BackgroundTaskMode:{MODE_DATA_TRANSFER:1,MODE_AUDIO_PLAYBACK:2},
 BackgroundTaskSubmode:{SUBMODE_LIVE_VIEW_NOTIFICATION:1,SUBMODE_AVSESSION_AUDIO_PLAYBACK:2},
 on:(name,callback)=>events.add(callback),off:(name,callback)=>events.delete(callback),
 async startBackgroundRunning(context,request){if(startFailure)throw Error('permission denied');const id=++sequence;starts.push({id,request});return {continuousTaskId:id,notificationId:id+100}},
 async stopBackgroundRunning(context,id){assert.equal(typeof id,'number','never stop all tasks');stops.push(id)} };
const mocks={'@kit.AbilityKit':{wantAgent:{OperationType:{START_ABILITY:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:1},getWantAgent:async()=>({})}},
 '@kit.BackgroundTasksKit':{backgroundTaskManager:system},
 '@kit.BasicServicesKit':{},
 '@kit.ArkData':{preferences:{getPreferences:async()=>({get:async(k,d)=>permissionPrefs.get(k)??d,
  put:async(k,v)=>permissionPrefs.set(k,v),flush:async()=>{}})}},
 '@kit.NotificationKit':{notificationManager:{ContentType:{NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW:8},SlotType:{LIVE_VIEW:4},
  isNotificationEnabled:async()=>notificationEnabled,getSlots:async()=>[{notificationType:4,enabled:liveEnabled}],
  async requestEnableNotification(){permissionRequests++;await new Promise(r=>setImmediate(r));if(!requestAllowed)throw {code:1600004};notificationEnabled=true},
  async openNotificationSettingsWithResult(){notificationEnabled=true;liveEnabled=true;return {}},
  async publish(value){if(publishFailure)throw Error('notification denied');notifications.push(value);if(publishHook){const hook=publishHook;publishHook=null;await hook()}}}},
 '../core/network/NasConnection':{NasConnection:{shared:()=>({setBackgroundTransferRunning(){}})}}};
function load(name){const exports={};const js=ts.transpileModule(fs.readFileSync('entry/src/main/ets/'+name+'.ets','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
 vm.runInNewContext(js,{exports,require:name=>{assert(mocks[name],name);return mocks[name]},AppStorage:{setOrCreate:(key,value)=>storage.set(key,value)},console,setTimeout,clearTimeout,Date});return exports}
const progress=load('transfer/TransferProgress');mocks['./TransferProgress']=progress;
const {TransferBackgroundManager:Manager}=load('transfer/TransferBackgroundManager');
const {VideoBackgroundTaskManager:Video}=load('media/VideoBackgroundTaskManager');
const context={abilityInfo:{bundleName:'cn.fhf.linkfiles',name:'EntryAbility'}};
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function settle(manager){for(let i=0;i<5;i++){await manager.queue;await tick()}}
const task=(id,extra={})=>Object.assign(new progress.TransferProgress(),{id,active:true,pending:true,bytes:100,doneBytes:25},extra);
const cancel=id=>{for(const callback of [...events])callback({id,reason:1})};
(async()=>{
 let manager=new Manager();manager.initialize(context);let cancelled=0;manager.onCancel(()=>cancelled++);
 manager.update('album',[task('old',{active:false,pending:false,done:1,doneBytes:100}),task('new')]);await settle(manager);
 assert.equal(starts.length,1);assert.equal(notifications.at(-1).template.data.progressValue,25);assert.deepEqual(Array.from(starts[0].request.backgroundTaskModes),[system.BackgroundTaskMode.MODE_DATA_TRANSFER]);assert.equal(notifications.at(-1).content.notificationContentType,8);assert.equal(notifications.at(-1).content.systemLiveView.capsule,undefined);assert.match(storage.get('transferProgressText'),/0\/1/);
 manager.setForeground(false);assert.equal(manager.canRun(),true);await settle(manager);
 const video=new Video();video.setPlaying(context,true);await video.queue;const videoId=starts.at(-1).id;
 manager.update('album',[]);await settle(manager);assert.equal(manager.canRun(),false);assert(!stops.includes(videoId));
 await video.release(context);assert(stops.includes(videoId));await manager.destroy();
 console.log('PASS: real protection gates background, excludes old history, and stops only its own task beside video');
 manager=new Manager();manager.initialize(context);startFailure=true;manager.update('upload',[task('fault')]);await settle(manager);
 assert(manager.canRun());manager.setForeground(false);await settle(manager);assert(!manager.canRun());const count=starts.length;
 startFailure=false;manager.update('upload',[task('fault',{doneBytes:50})]);await settle(manager);assert.equal(starts.length,count);
 manager.setForeground(true);await settle(manager);assert(storage.get('transferProtectionActive'));manager.setForeground(false);
 cancel(manager.taskId);await settle(manager);assert(!manager.canRun());assert.match(storage.get('transferProtectionError'),/停止/);
 const afterCancel=starts.length;manager.update('upload',[task('fault',{doneBytes:60})]);await settle(manager);assert.equal(starts.length,afterCancel);
 manager.setForeground(true);await manager.requestResume();await settle(manager);assert(manager.healthy);
 await manager.destroy();console.log('PASS: denied protection preserves foreground, cancels safely, and needs explicit resume after system cancellation');
 manager=new Manager();manager.initialize(context);publishFailure=true;manager.update('download',[task('notice',{direction:'download'})]);await settle(manager);
 assert(!manager.healthy);assert(stops.includes(starts.at(-1).id));manager.setForeground(false);assert(!manager.canRun());
 publishFailure=false;await manager.destroy();
 manager.initialize(context);publishHook=async()=>cancel(manager.taskId);manager.update('upload',[task('race')]);await settle(manager);
 assert(!manager.healthy,'late publish must not resurrect cancelled protection');assert.equal(manager.taskId,-1);
 await manager.destroy();assert(!manager.canRun(),'destroyed ability cannot continue without protection');manager.initialize(context);manager.update('upload',[task('recreated')]);await settle(manager);assert(manager.healthy);
 const before=notifications.length;for(let i=0;i<10;i++)manager.update('upload',[task('recreated',{doneBytes:30+i})]);await settle(manager);
 assert.equal(notifications.length,before,'progress notification is throttled');await new Promise(resolve=>setTimeout(resolve,1050));await settle(manager);assert.equal(notifications.length,before+1);
 await manager.destroy();assert.equal(events.size,0);
 console.log('PASS: notification failure releases task; cancellation during publish stays cancelled; recreation and bounded update rate');
 const summary=progress.summarizeTransfers([task('album',{count:3,done:2,skipped:1,bytes:300,doneBytes:200}),task('download',{direction:'download',doneBytes:50})]);
 assert.equal(summary.percent,62);assert.equal(summary.count,4);assert.equal(summary.skipped,1);
 assert.equal(progress.summarizeTransfers([task('failed',{doneBytes:100,failed:1})]).percent,99);
 assert.equal(progress.summarizeTransfers([task('unknown',{bytes:0})]).knownSize,false);
 console.log('PASS: weighted upload/download totals, skipped count, unknown size and failed items never report success');
 notificationEnabled=false;permissionPrefs.clear();manager=new Manager();manager.initialize(context);
 await Promise.all([manager.requestNotificationPermission(),manager.requestResume()]);assert.equal(permissionRequests,1);
 assert.equal(permissionPrefs.get('notification_permission_requested_v1'),true);
 manager.update('album',[task('permission-granted')]);await settle(manager);assert(manager.healthy);
 await manager.destroy();manager=new Manager();manager.initialize(context);await manager.requestNotificationPermission();assert.equal(permissionRequests,1);
 await manager.destroy();notificationEnabled=false;requestAllowed=false;permissionPrefs.clear();
 manager=new Manager();manager.initialize(context);await manager.requestNotificationPermission();assert.equal(permissionRequests,2);
 manager.update('album',[task('denied')]);await settle(manager);assert(!manager.healthy);assert(manager.canRun());
 manager.setForeground(false);await settle(manager);assert(!manager.canRun());await manager.destroy();
 manager=new Manager();manager.initialize(context);await manager.requestNotificationPermission();assert.equal(permissionRequests,2,'rejection survives relaunch without another prompt');
 notificationEnabled=true;liveEnabled=false;manager.update('album',[task('slot-disabled')]);await settle(manager);assert(!manager.healthy);
 await manager.openNotificationSettings();await settle(manager);assert(manager.healthy);assert.equal(storage.get('transferNotificationBlocked'),false);
 await manager.destroy();console.log('PASS: official first-use prompt is shared and persisted; rejection/disabled live-view never falsely protects; settings restore protection');
})().catch(error=>{console.error(error);process.exitCode=1});

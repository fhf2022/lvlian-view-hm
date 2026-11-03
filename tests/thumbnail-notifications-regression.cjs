const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require(process.argv[2]);
let now=100000,serial=0,timers=new Map(),sockets=[];
class Socket {
 constructor(){this.events={};this.sent=[];this.closed=0;sockets.push(this)}
 on(type,fn){this.events[type]=fn}off(type){delete this.events[type]}
 connect(url,options){this.url=url;this.options=options;return Promise.resolve(true)}
 send(text){this.sent.push(text);return Promise.resolve(true)}
 close(){this.closed++;return Promise.resolve(true)}
 emit(type,value){this.events[type]?.(null,value)}
}
const globals={console,Date:{now:()=>now},setTimeout(fn,delay){const id=++serial;timers.set(id,{fn,delay,interval:false});return id},clearTimeout(id){timers.delete(id)},
 setInterval(fn,delay){const id=++serial;timers.set(id,{fn,delay,interval:true});return id},clearInterval(id){timers.delete(id)},
 require(name){if(name==='@kit.NetworkKit')return{webSocket:{createWebSocket:()=>new Socket()}};if(name==='@kit.ArkTS')return{util:{generateRandomUUID:()=> 'test-client-'+(++serial)}};throw Error(name)}};
function load(path){const exports={};vm.runInNewContext(ts.transpileModule(fs.readFileSync(path,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,{...globals,exports});return exports}
const {ThumbnailNotifications:Notifications}=load('entry/src/main/ets/ugreen/ThumbnailNotifications.ets');
const {PreviewLoadQueue:Queue}=load('entry/src/main/ets/media/PreviewLoadQueue.ets');
const tick=async()=>{for(let i=0;i<40;i++)await Promise.resolve()};
const ready=(socket,id)=>socket.emit('message',JSON.stringify({type:'filemgr',app_id:'com.ugreen.filemgr',data:{event:'thumbnail-done',body:{list:[{thumb_id:id}]}}}));
(async()=>{
 const channel=new Notifications(),delivered=[];channel.setListener(path=>delivered.push(path));
 const first=channel.ensure('https://nas.invalid',{'x-ugreen-token':'fake-token'});
 const second=channel.ensure('https://nas.invalid',{'x-ugreen-token':'fake-token'});
 assert.equal(sockets.length,1,'concurrent thumbnails share one connection');const socket=sockets[0];
 assert.equal(timers.size,1,'one connection timeout, no timer per thumbnail');socket.emit('open');assert.ok(await first);assert.ok(await second);
 const headers=channel.requestHeaders('/photos/one');assert.equal(new URL(socket.url).searchParams.get('client_id'),headers['Client-ID']);
 assert.equal(headers['App-ID'],'com.ugreen.filemgr');assert.equal(channel.requestHeaders('/photos/one')['Thumb-ID'],headers['Thumb-ID']);
 assert.ok(!socket.url.includes('fake-token'),'credentials remain in handshake headers');assert.equal(socket.options.header['x-ugreen-token'],'fake-token');
 for(const value of ['bad json','null','{"data":null,"event":"thumbnail-done"}',JSON.stringify({data:{event:'other',body:{list:[]}}})])socket.emit('message',value);
 ready(socket,'unknown-id');assert.equal(delivered.length,0);ready(socket,headers['Thumb-ID']);assert.deepEqual(delivered,['/photos/one']);
 channel.forgetPending();ready(socket,headers['Thumb-ID']);assert.equal(delivered.length,1,'cancelled bindings cannot wake a new scene');
 const fresh=channel.requestHeaders('/photos/one');channel.complete('/photos/one',headers['Thumb-ID']);ready(socket,fresh['Thumb-ID']);assert.equal(delivered.length,2,'old HTTP completion cannot remove a new owner');
 channel.complete('/photos/one',fresh['Thumb-ID']);ready(socket,fresh['Thumb-ID']);assert.equal(delivered.length,2);
 const oldest=channel.requestHeaders('/many/0');for(let i=1;i<=256;i++)channel.requestHeaders('/many/'+i);ready(socket,oldest['Thumb-ID']);assert.equal(delivered.length,2,'mapping size stays bounded');
 channel.setForeground(false);assert.equal(timers.size,0);assert.equal(socket.closed,1);assert.equal(await channel.ensure('https://nas.invalid',{}),false);
 channel.setForeground(true);const reopened=channel.ensure('https://nas.invalid',{});const next=sockets.at(-1);next.emit('open');await reopened;
 const priorClient=channel.requestHeaders('/account/one')['Client-ID'];channel.reset();assert.equal(timers.size,0);
 const switched=channel.ensure('https://other.invalid',{});const other=sockets.at(-1);other.emit('open');await switched;
 assert.notEqual(channel.requestHeaders('/account/one')['Client-ID'],priorClient,'account reset isolates notification identity');channel.stop();
 const unavailable=new Notifications(),failure=unavailable.ensure('https://nas.invalid',{});const stalled=sockets.at(-1);
 const timeout=[...timers.values()].find(t=>!t.interval);timeout.fn();assert.equal(await failure,false);assert.equal(stalled.closed,1);assert.equal(timers.size,0);
 const count=sockets.length;assert.equal(await unavailable.ensure('https://nas.invalid',{}),false);assert.equal(sockets.length,count,'unavailable socket has a bounded cooldown');
 // A real production queue: readiness may arrive either before or after HTTP 423.
 now+=6000;const queue=new Queue(4,256);let calls=0;
 queue.enqueue('deferred',0,async()=>{if(++calls===1)throw Error('423')},()=>true,()=>true,()=>15000);await tick();
 assert.equal(calls,1);assert.equal([...timers.values()][0].delay,15000,'connected channel waits for an event before the fallback');
 queue.retryNow('deferred');await tick();assert.equal(calls,2);assert.equal(queue.pendingCount(),0);assert.equal(timers.size,0);
 let reject;calls=0;queue.enqueue('early',0,()=>{calls++;return calls===1?new Promise((_,fail)=>reject=fail):Promise.resolve()},()=>true,()=>true,()=>15000);
 queue.retryNow('early');queue.retryNow('early');reject(Error('423'));await tick();assert.equal(calls,2,'early and duplicate events coalesce into one follow-up');
 calls=0;queue.enqueue('cancelled',0,async()=>{calls++;throw Error('423')},()=>true,()=>true,()=>15000);await tick();queue.cancelPending();queue.retryNow('cancelled');await tick();assert.equal(calls,1);assert.equal(timers.size,0);
 // Background cancellation must not leave an old scrolling flag blocking resume.
 const source=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
 const start=source.indexOf('  onAbilityBackgroundChanged(): void {'),end=source.indexOf('\n  onTransferNavigationRequested()',start);
 const exported={};vm.runInNewContext(ts.transpileModule('export class Page {\n'+source.slice(start,end)+'\n}',{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
  {exports:exported,NasConnection:{shared:()=>({setForeground(){}})}});
 const page=new exported.Page(),foreground=[];let cancelled=0,warmed=0;
 Object.assign(page,{startupAuthorized:true,gestureSharePageVisible:true,abilityInBackground:true,fileContentScrolling:true,previewGeneration:9,
  repository:{setThumbnailForeground:value=>foreground.push(value)},albumUpload:{setForeground(){}},cancelPendingPreviewLoads(){cancelled++},
  scheduleNasRecovery(){},syncGestureShareRegistration(){},handlePlaybackBackgroundState(){},schedulePreviewWarmup(generation){assert.equal(generation,9);warmed++},
  onContinuationNoticeChanged(){},onContinuationMessage(){},onIncomingShareRequested(){},scheduleVideoPipRestore(){}});
 page.onAbilityBackgroundChanged();assert.equal(cancelled,1);assert.equal(page.fileContentScrolling,false);assert.equal(warmed,0);
 page.abilityInBackground=false;page.onAbilityBackgroundChanged();assert.equal(warmed,1);assert.deepEqual(foreground,[false,true]);
 console.log('PASS thumbnail notifications: shared authenticated channel, bounded mapping, owner/session isolation, timeout/background cleanup, and queue readiness races');
})().catch(error=>{console.error(error);process.exitCode=1});

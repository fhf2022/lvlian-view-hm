const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require(process.argv[2]);
const source=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
function method(text,name){const a=text.search(new RegExp('^  private (?:async )?'+name+'\\(','m'));assert.ok(a>=0,name);const b=text.slice(a+1).search(/^  (?:private |@Builder|async |[a-zA-Z]+\()/m);return text.slice(a,a+b+1)}
function compile(text,globals={}){const exports={};vm.runInNewContext(ts.transpileModule(text,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,{exports,console,...globals});return exports;}
class Failure extends Error{constructor(status){super('test');this.status=status}}
const names=['finishPreparedFileTransition','resetPreviewState','resetWaterfallDirectoryState','schedulePreviewWarmup','previewPriority','loadEntryPreview','loadEntryPreviewNow','noteVisibleEntryForLoad','refreshVisiblePreviewIfNeeded','flushPendingVisibleLoads'];
const {Page}=compile('export class Page {\n'+names.map(n=>method(source,n)).join('\n')+'\n}',{hilog:{info(){}},IMAGE_VIEWER_HILOG_DOMAIN:0,UgreenError:Failure,CacheManager:{exists:()=>false}});
function fixture(mode='grid',cached=0,folders=0){
 const p=new Page(),frames=[],admitted=[],notified=[];p.gestureSharePageVisible=true;
 const entries=Array.from({length:100},(_,i)=>({path:'/album/'+i,name:i+'.jpg',index:i,isDirectory:i<folders,kind:i%3}));
 Object.assign(p,{entries,screen:'files',showSearch:false,showImageViewer:false,viewerEntryTransitionActive:false,viewerClosePending:false,fileViewMode:mode,
 previewGeneration:3,resetPreviewAfterPageTransition:true,showPageTransition:true,pageTransitionToken:1,fileVisibleStartIndex:0,fileVisibleEndIndex:31,
 previewRecoveryAttempts:new Map(),previewReloadPaths:new Set(),previewRequests:{},pendingVisibleLoads:new Map(),gridRenderedPreviewKey:{},waterfallRenderedPreviewKey:{},
 previewRequestSequence:0,previewDuplicateBlockedCount:0,locateProgrammaticScrolling:false,locateTargetIndex:-1,timelineScrubActive:false,fileContentScrolling:true,
 repository:{cancelThumbnailNotifications(){}},networkPolicy:{isMetered:()=>false},isImage:e=>!e.isDirectory&&(mode!=='list'||e.kind===0),isVideo:e=>mode==='list'&&e.kind===1,isAudio:e=>mode==='list'&&e.kind===2,
 previewUri:e=>e.index<cached?'file://cached/'+e.index:'',isPreviewRequestActive:path=>p.previewRequests[path]>0,
 resolveFileListImageRotation(){},acquirePathGeneration:()=>1,previewQueue:{enqueue(key){admitted.push(key);return true},cancelPending(){},promote(){}},
 notifyEntryChanged(path){notified.push(path);p.gridRenderedPreviewKey[path]=p.previewUri(entries.find(e=>e.path===path))},
 fileEntryDataSource:{indexOfPath:path=>entries.findIndex(e=>e.path===path)},postRenderFrame:fn=>frames.push(fn),rememberGridViewportAnchor(){},stopWaterfallPipeline(){},resetFileListScroll(){}});
 return {p,entries,admitted,notified,frame(){frames.splice(0).forEach(fn=>fn())}};
}
let h=fixture();for(const e of h.entries.slice(0,32))h.p.noteVisibleEntryForLoad(e,1);
h.p.pendingVisibleLoads.set('/old/path',{path:'/old/path'});h.p.finishPreparedFileTransition(1);
assert.equal(h.p.fileContentScrolling,false);assert.equal(h.p.pendingVisibleLoads.size,32);assert.equal(h.p.fileVisibleEndIndex,31);
assert.equal(h.admitted.length,0,'no preview work before the committed frame');h.frame();
assert.equal(new Set(h.admitted).size,32,'all visible cells load without any scroll, not only the warmup limit');
h=fixture('grid',16);for(const e of h.entries.slice(0,32)){h.p.gridRenderedPreviewKey[e.path]='';h.p.noteVisibleEntryForLoad(e,1)}
h.p.finishPreparedFileTransition(1);h.frame();assert.equal(h.notified.length,16);assert.equal(h.admitted.length,16);
h.p.schedulePreviewWarmup(h.p.previewGeneration);h.frame();assert.equal(h.notified.length,16,'already-reconciled cached cells are not rebuilt');
h=fixture('grid',100);for(const e of h.entries.slice(0,32)){h.p.gridRenderedPreviewKey[e.path]=h.p.previewUri(e);h.p.noteVisibleEntryForLoad(e,1)}
h.p.finishPreparedFileTransition(1);h.frame();assert.equal(h.notified.length,0,'already-painted cached screen needs no extra refresh');
h=fixture('grid',0,33);h.p.fileVisibleStartIndex=33;h.p.fileVisibleEndIndex=60;
for(const e of h.entries.slice(33,61))h.p.noteVisibleEntryForLoad(e,1);h.p.finishPreparedFileTransition(1);h.frame();
assert.equal(h.admitted.length,28,'leading folders cannot consume the actual viewport budget');
h=fixture('list');h.p.fileVisibleStartIndex=1;h.p.fileVisibleEndIndex=28;h.p.finishPreparedFileTransition(1);h.frame();
assert.ok(h.entries.slice(0,28).every(e=>h.admitted.some(key=>key.startsWith(e.path+'#'))),'list header mapping covers images, videos and audio in the current screen');
assert.ok(h.admitted.length<=40,'adjacent list preloads remain bounded');
for(const change of [p=>p.previewGeneration++,p=>p.screen='login',p=>p.showImageViewer=true,p=>p.fileContentScrolling=true,p=>p.locateProgrammaticScrolling=true,p=>p.timelineScrubActive=true]){
 h=fixture();h.p.finishPreparedFileTransition(1);change(h.p);h.frame();assert.equal(h.admitted.length,0,'late warmup cannot load another scene or interrupt a new gesture');
}
console.log('PASS first-screen previews: transition observations, cold/cached/painted cells, leading folders, mixed-media list, stale generations and gesture/viewer guards');

const repository=fs.readFileSync('entry/src/main/ets/repository/UgreenRemoteRepository.ets','utf8');
const {Repository}=compile('export class Repository {\n'+['prepareThumbnailOnce','fetchAndNormalizeThumbnail'].map(n=>method(repository,n)).join('\n')+'\n}',{
 UgreenError:Failure,UgreenErrorKind:{NAS_UNAVAILABLE:'offline'},CacheManager:{exists:()=>false,cachePath:()=>'/cache/miss'},NasConnection:{shared:()=>({canRequest:()=>true})}
});
let now=0,sequence=0,timers=new Map(),maxTimers=0;
const {PreviewLoadQueue:Queue}=compile(fs.readFileSync('entry/src/main/ets/media/PreviewLoadQueue.ets','utf8'),{
 Date:{now:()=>now},setTimeout(fn,delay){const id=++sequence;timers.set(id,{fn,due:now+delay});maxTimers=Math.max(maxTimers,timers.size);return id},clearTimeout(id){timers.delete(id)}
});
const tick=async()=>{for(let i=0;i<150;i++)await Promise.resolve()};
async function advance(){assert.ok(timers.size);now=Math.min(...[...timers.values()].map(t=>t.due));const due=[...timers].filter(([id,t])=>t.due<=now);for(const [id,t]of due){timers.delete(id);t.fn()}await tick()}
const recover=e=>e instanceof Failure&&e.status===423;
(async()=>{
 const q=new Queue(4,256),done=[],calls=new Map();let simultaneous=0,peak=0;
 for(let i=0;i<35;i++)q.enqueue('file-'+i,0,async()=>{simultaneous++;peak=Math.max(peak,simultaneous);await Promise.resolve();simultaneous--;calls.set(i,(calls.get(i)||0)+1);if(i===0&&now<6000)throw new Failure(423);done.push(i)},recover,()=>true);
 await tick();assert.equal(done.length,34,'locked image releases its worker; remaining screen starts immediately');assert.ok(peak<=4);assert.equal(q.activeCountValue(),0);assert.equal(timers.size,1);
 let duplicateRan=false;assert.equal(q.enqueue('file-0',0,async()=>{duplicateRan=true}),false,'deferred tasks keep their identity');
 while(timers.size)await advance();assert.equal(done.length,35);assert.equal(duplicateRan,false);assert.equal(calls.get(0),4);assert.equal(maxTimers,1);
 const permanent=new Queue(4,256);let attempts=0;permanent.enqueue('locked',0,async()=>{attempts++;throw new Failure(423)},recover,()=>true);await tick();while(timers.size)await advance();assert.equal(attempts,6,'initial request plus at most five deferred attempts');assert.equal(permanent.pendingCount(),0);
 for(const status of [401,403,404,500,503]){const isolated=new Queue();let n=0;isolated.enqueue('failure',0,async()=>{n++;throw new Failure(status)},recover,()=>true);await tick();assert.equal(n,1);assert.equal(timers.size,0)}
 const cancelled=new Queue(4,256);let valid=true,reads=0;cancelled.enqueue('cancel',0,async()=>{if(!valid)return;reads++;throw new Failure(423)},recover,()=>valid);await tick();valid=false;assert.deepEqual([...cancelled.cancelPending()],['cancel']);assert.equal(timers.size,0);assert.equal(reads,1);
 const running=new Queue();let release,active=true,ran=0;running.enqueue('active',0,async()=>{ran++;await new Promise(r=>release=r);throw new Failure(423)},recover,()=>active);active=false;release();await tick();assert.equal(timers.size,0);assert.equal(ran,1,'leaving while the response is in flight cannot revive retries');
 const bounded=new Queue(1,2);let unblock;bounded.enqueue('busy',0,()=>new Promise(r=>unblock=r));assert.equal(bounded.enqueue('a',0,async()=>{}),true);assert.equal(bounded.enqueue('b',0,async()=>{}),true);assert.equal(bounded.enqueue('overflow',0,async()=>{}),false);bounded.clear();unblock();await tick();assert.equal(bounded.pendingCount(),0);
 console.log('PASS deferred thumbnail queue: one timer, 35-file fairness, four-worker bound, duplicate promotion, finite 423 recovery, other status isolation, cancellation and pending cap');
 // Full production error path: repository route -> inner preview catch -> queue -> same cell publication.
 const repo=new Repository();let binaryCalls=0,registered=0;
 Object.assign(repo,{cacheScopeHash:()=> 'a',signatureForFile:()=>({key:()=> 'signature'}),thumbnailIdentityKey:()=> 'identity',thumbnailCacheKey:()=> 'route',thumbnailRequests:new Map(),
 thumbnailCacheStore:{find:async()=>'',register:async()=>{registered++}},client:{completeThumbnail(){},thumbnailCandidates:async()=>[{url:'https://example.invalid/thumbnail',headers:{},fileName:'image.thumbnail'}]},
 transport:{requestBinary:async()=>{if(++binaryCalls===1)throw new Failure(423);return new Uint8Array([1])}},thumbnailNormalizer:{prepare:async()=>({path:'/cache/ready'})}});
 repo.prepareThumbnail=repo.prepareThumbnailOnce.bind(repo);repo.thumbnailNotificationsConnected=()=>false;
 const flow=fixture(),p=flow.p,entry=flow.entries[0],published=[];p.showPageTransition=false;p.fileContentScrolling=false;
 Object.assign(p,{repository:repo,previewQueue:new Queue(4,256),previewLocalPaths:{},thumbnailDirectory:'/cache',thumbnailCacheLimitBytes:1000,
 isPathGenerationValid:()=>true,ensureCacheState:async()=>{},mediaPreviewManager:{cachedImagePreview:()=>''},imageTelemetry:{recordStaleCompletion(){}},
 publishThumbnailPreview:async(e,path)=>{published.push(path)},previewUri:()=>''});
 p.loadEntryPreview(entry);await tick();assert.equal(binaryCalls,1);assert.equal(timers.size,1,'repository 423 must reach the delayed queue, not disappear in a catch');
 p.loadEntryPreview(entry);await tick();assert.equal(binaryCalls,1,'visibility callback promotes deferred task without resetting its owner');
 await advance();assert.equal(binaryCalls,2);assert.deepEqual(published,['/cache/ready']);assert.equal(registered,2);assert.equal(p.previewRequests[entry.path],0);
 p.viewerBlocksFileContent=true;p.previewQueue=new Queue(4,256);p.loadEntryPreview(entry);await tick();assert.equal(binaryCalls,2,'opening the viewer must not start a file-surface thumbnail task');
 console.log('PASS integrated production preview recovery: 423 propagates through both catches, deduplicates during delay and publishes the recovered cell');
})().catch(error=>{console.error(error);process.exitCode=1});

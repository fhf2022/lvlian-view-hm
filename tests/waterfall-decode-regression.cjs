const fs=require('node:fs'),assert=require('node:assert/strict'),vm=require('node:vm'),ts=require(process.argv[2]);
const src=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
function method(name){const a=src.search(new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m'));assert.ok(a>=0,name);const rest=src.slice(a+1),b=rest.search(/^  (?:private |@Builder|aboutTo|onBackPress\(|build\()/m);return src.slice(a,a+b+1)}
const ex={};vm.runInNewContext(ts.transpileModule('export class Pipeline {\n'+['decodeWaterfallBitmap','completeWaterfallDecode','failWaterfallDecode','markWaterfallVisible'].map(method).join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:ex,console,fileUri:{getUriFromPath:p=>'file://'+p}});
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve}};
const entry={path:'/photo/a.jpg'};
function fixture(){const p=new ex.Pipeline(),gate=deferred(),record={displayWidth:1200,displayHeight:1600};Object.assign(p,{waterfallGeneration:7,fileViewMode:'waterfall',waterfallVisiblePaths:{[entry.path]:true},waterfallActiveDecodes:1,waterfallActiveDecodePaths:{[entry.path]:8},waterfallDecodedPaths:{},waterfallBitmaps:{},waterfallRasterFailed:{},waterfallLocalRevisions:{},waterfallResourceResident:()=>true,notifyEntryChanged(){},fileContentScrolling:false,timelineScrubActive:false,showImageViewer:false,installed:0,released:0,drained:0,warmed:0,renewed:0,enqueueWaterfallDecode(){p.renewed++},
imageVisualState:()=>({userRotation:0}),waterfallAspectRatioReady:()=>true,waterfallSourceSize:()=>({width:600,height:800}),viewerBitmapStore:{decode:()=>gate.promise,async release(){p.released++}},installViewerBitmap(){p.installed++},applyDecodedBitmapGeometry(){},setWaterfallAspectRatio(){},setWaterfallOriginalUri(){},drainWaterfallDecodes(){p.drained++},warmTimelineVisibleEntries(){p.warmed++},recoverEntryPreview(){},async releaseViewerBitmap(){}});return{p,gate,record};}
(async()=>{
for(const change of [p=>p.timelineScrubActive=true,p=>p.showImageViewer=true,p=>p.waterfallGeneration++,p=>p.fileViewMode='grid',p=>p.waterfallVisiblePaths[entry.path]=false,p=>p.waterfallResourceResident=()=>false,p=>p.imageVisualState=()=>({userRotation:90})]){
 const {p,gate,record}=fixture();const running=p.decodeWaterfallBitmap(entry,'/cache/a',7);assert.equal(p.waterfallActiveDecodes,1);change(p);p.failWaterfallDecode(entry);assert.equal(p.waterfallActiveDecodes,1,'fallback Image error must not release active native decoder');gate.resolve(record);await running;assert.equal(p.installed,0,'busy or obsolete decode must not publish');assert.equal(p.released,1);assert.equal(p.waterfallActiveDecodes,0);assert.equal(p.drained,1);assert.equal(p.warmed,p.waterfallGeneration===7?0:1);
}
const {p,gate,record}=fixture();p.fileContentScrolling=true;const running=p.decodeWaterfallBitmap(entry,'/cache/a',7);gate.resolve(record);await running;assert.equal(p.installed,1);assert.equal(p.released,0);assert.equal(p.waterfallActiveDecodes,0);
// Null/error results from old/offscreen sources cannot poison a restored row.
for(const change of [p=>p.waterfallVisiblePaths[entry.path]=false,p=>p.waterfallResourceResident=()=>false,p=>p.waterfallLocalRevisions[entry.path]=1,p=>p.showImageViewer=true]){
 for(const reject of [false,true]){
  const {p,gate}=fixture();if(reject)p.viewerBitmapStore.decode=()=>gate.promise.then(()=>{throw Error('old source failed')});
  const pending=p.decodeWaterfallBitmap(entry,'/cache/a',7);change(p);gate.resolve(null);await pending;
  assert.notEqual(p.waterfallRasterFailed[entry.path],true,'obsolete null/error cannot mark a new source failed');
  assert.equal(p.renewed,p.waterfallLocalRevisions[entry.path]===1?1:0,'a source renewed behind an active decoder is rescheduled');
 }
}
const failed=fixture();const failing=failed.p.decodeWaterfallBitmap(entry,'/cache/a',7);failed.gate.resolve(null);await failing;
assert.equal(failed.p.waterfallRasterFailed[entry.path],true,'a current failure stays bounded until source renewal or group restoration');
const visit=fixture().p;visit.waterfallVisiblePaths[entry.path]=false;visit.waterfallRasterFailed[entry.path]=true;
visit.markWaterfallVisible(entry,true);assert.equal(visit.waterfallRasterFailed[entry.path],false,'reentering a visible cell permits recovery without leaving waterfall');
visit.waterfallRasterFailed[entry.path]=true;visit.markWaterfallVisible(entry,true);assert.equal(visit.waterfallRasterFailed[entry.path],true,'duplicate visibility events do not clear a failed attempt');
visit.waterfallVisiblePaths[entry.path]=false;visit.waterfallAspectRatioReady=()=>false;visit.markWaterfallVisible(entry,true);assert.equal(visit.waterfallRasterFailed[entry.path],true,'unsupported geometry is not retried as a raster');
const policy={};vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/media/ThumbnailPolicy.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:policy});
const qx={};vm.runInNewContext(ts.transpileModule('export class Queue {\n'+['enqueueWaterfallDecode','drainWaterfallDecodes','onFileContentScrollStart'].map(method).join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:qx,ThumbnailPolicy:policy.ThumbnailPolicy,TAP_TRACE:false,ContinuationManager:{shared:()=>({refresh(){}})}});
const q=new qx.Queue(),jobs=[];let active=0,peak=0;
Object.assign(q,{fileViewMode:'waterfall',fileContentScrolling:true,timelineScrubActive:false,showImageViewer:false,waterfallResourceResident:()=>true,waterfallVisiblePaths:{},waterfallLocalPaths:{},waterfallLocalSignatures:{},waterfallRasterFailed:{},waterfallDecodedPaths:{},waterfallActiveDecodePaths:{},waterfallDecodeQueue:[],waterfallActiveDecodes:0,waterfallGeneration:7,waterfallEntrySignature:e=>e.path,
decodeWaterfallBitmap(e){peak=Math.max(peak,++active);jobs.push({entry:e,finish(){active--;q.waterfallActiveDecodePaths[e.path]=0;q.waterfallDecodedPaths[e.path]=true;q.waterfallActiveDecodes--;q.drainWaterfallDecodes()}})},
noteUserInteraction(){},fileListScroller:{currentOffset:()=>({yOffset:0})},returnPerfSession:{noteScrollStart(){}},getMonotonicNow:()=>0,cancelPendingPreviewLoads(){},releaseTimelineFocusPinFromFileScroll(){}});
const entries=Array.from({length:8},(_,i)=>({path:'/photo/'+i}));
for(const e of entries){q.waterfallVisiblePaths[e.path]=true;q.waterfallLocalPaths[e.path]='/cache/'+e.path;q.waterfallLocalSignatures[e.path]=e.path;q.enqueueWaterfallDecode(e);q.enqueueWaterfallDecode(e)}
assert.equal(jobs.length,policy.ThumbnailPolicy.WATERFALL_MAX_CONCURRENT_DECODES,'moving viewport fills the fixed limit');assert.equal(q.waterfallDecodeQueue.length,entries.length-jobs.length,'repeated visible callbacks never duplicate queued work');
const pending=q.waterfallDecodeQueue.length;q.onFileContentScrollStart();assert.equal(q.waterfallDecodeQueue.length,pending,'starting another swipe preserves queued visible decodes');
q.waterfallVisiblePaths[entries.at(-1).path]=false;
for(let i=0;i<jobs.length;i++)jobs[i].finish();
assert.equal(jobs.length,7,'queued image leaving the viewport is skipped');assert.equal(peak,policy.ThumbnailPolicy.WATERFALL_MAX_CONCURRENT_DECODES);assert.equal(q.waterfallActiveDecodes,0);
q.fileContentScrolling=false;q.waterfallDecodedPaths[entries[0].path]=false;q.enqueueWaterfallDecode(entries[0]);assert.equal(q.waterfallActiveDecodes,1,'idle uses the same fixed limit');jobs.at(-1).finish();
// Execute the production original-ready callback, including the failure reset.
const readyStart=src.indexOf('      ready: async (entry: FileEntry, path: string, valid: () => boolean)');
const readyEnd=src.indexOf('      finished:',readyStart);assert.ok(readyStart>0&&readyEnd>readyStart);
const rx={};vm.runInNewContext(ts.transpileModule('export class Renewal { callbacks() { return {'+src.slice(readyStart,readyEnd)+'} } }',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:rx});
const renewal={waterfallLocalPaths:{},waterfallLocalSignatures:{},waterfallLocalRevisions:{},waterfallRasterFailed:{[entry.path]:true},waterfallEntrySignature:()=> 'version1',calls:0,enqueueWaterfallDecode(){this.calls++}};
const ready=rx.Renewal.prototype.callbacks.call(renewal).ready;
await ready(entry,'/cache/renewed',()=>false);assert.equal(renewal.calls,0);assert.equal(renewal.waterfallRasterFailed[entry.path],true);
await ready(entry,'/cache/renewed',()=>true);assert.equal(renewal.waterfallRasterFailed[entry.path],false);assert.equal(renewal.waterfallLocalRevisions[entry.path],1);assert.equal(renewal.calls,1);
await ready(entry,'/cache/renewed',()=>true);assert.equal(renewal.waterfallLocalRevisions[entry.path],2,'same-path replacement still has a new source revision');
console.log('PASS actual waterfall decoder: native slot ownership, timeline/viewer cancellation, stale generation release and scroll-time commit');
})().catch(e=>{console.error(e);process.exitCode=1});

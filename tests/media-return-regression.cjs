const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),ts=require(process.argv[2]);
const source=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
const names=['scrollMediaReturnSourceIntoView','scrollItemIntoContentBand','prepareMediaReturnSource','prepareViewerReturnSource','mediaReturnBandTop','mediaReturnBandBottom'];
const method=name=>{const start=source.search(new RegExp('^  private (?:async )?'+name+'\\(','m'));assert.ok(start>=0,name);const end=source.slice(start+1).search(/^  (?:private |@Builder)/m);return source.slice(start,start+end+1)};
const exportsObject={};
vm.runInNewContext(ts.transpileModule('export class Harness {\n'+names.map(method).join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,
 {exports:exportsObject,console,Math,Promise,setTimeout,IMAGE_RETURN_MOUNT_FRAME_LIMIT:8,ScrollAlign:{AUTO:3}});
const entry={path:'/music/track.flac'},other={path:'/music/other.flac'};
function make(){
 const h=new exportsObject.Harness(),events=[];let rect={y:160,height:60};
 const scroller={getItemRect(i){events.push(['rect',i]);return rect},scrollToIndex(i,anim,align){events.push(['index',i,anim,align])},scrollBy(x,y){events.push(['by',x,y]);rect={...rect,y:rect.y-y}}};
 Object.assign(h,{screen:'files',showSearch:false,fileViewMode:'list',entries:[other,entry],waterfallEntries:[entry,other],searchResults:[other,entry],
  nativeFileChildIndex:(_scroller,index)=>index,fileChildRect:(scroller,index)=>scroller.getItemRect(index),
  fileListScroller:scroller,waterfallScroller:scroller,searchResultScroller:scroller,pageHeightVp:800,
  targetLocateEntryPath:'',fileScrollViewport:{y:40,height:760},fileContentTopInset:()=>134,topSafeInset:()=>40,floatingBarContentInset:()=>76,nextRenderFrame:async()=>{},
  showImageViewer:true,viewerImageEntry:entry,hasViewerTransitionSource:()=>true,
  ensureViewerPreviewBitmap:async()=>{events.push(['preview'])},ensureWaterfallIndex:async()=>{},waterfallLocalIndex:i=>i});
 return {h,events,setRect:r=>{rect=r}};
}
async function run(){
 let t=make();assert.equal(await t.h.prepareViewerReturnSource(entry),true);
 assert.equal(t.h.viewerReturnReadyPath,entry.path);assert.equal(t.events.filter(e=>e[0]==='by'||e[0]==='index').length,0,'visible image retains its exact file-page position');
 assert.equal(t.events.filter(e=>e[0]==='preview').length,1);
 t=make();t.setRect({y:60,height:60});assert.equal(await t.h.prepareMediaReturnSource(entry,()=>true,()=>true),true);
 assert.deepEqual(t.events.find(e=>e[0]==='by'),['by',0,-34],'clip above header: move only to nearest visible edge');
 t=make();t.setRect({y:740,height:60});await t.h.prepareMediaReturnSource(entry,()=>true,()=>true);
 assert.deepEqual(t.events.find(e=>e[0]==='by'),['by',0,116],'clip below floating bar: minimal move, never center');
 t=make();t.setRect({y:-15,height:61});let pendingDelta=0,frameTick=0,actualY=-15;
 t.h.fileListScroller.scrollBy=(x,y)=>{t.events.push(['by',x,y]);pendingDelta+=y};
 t.h.nextRenderFrame=async()=>{frameTick++;if(frameTick===2){actualY-=pendingDelta;pendingDelta=0;t.setRect({y:actualY,height:61})}};
 assert.equal(await t.h.prepareMediaReturnSource(entry,()=>true,()=>actualY>=94),true);
 assert.equal(t.events.filter(e=>e[0]==='by').length,1,'pre-layout callbacks must not apply the same minimal correction twice');
 t=make();t.h.fileScrollViewport={y:0,height:800};t.setRect({y:100,height:60});
 await t.h.prepareMediaReturnSource(entry,()=>true,()=>true);
 assert.deepEqual(t.events.find(e=>e[0]==='by'),['by',0,-34],'safe-area-expanded viewport uses its measured origin, not a fixed status-bar offset');
 t=make();t.h.fileViewMode='waterfall';await t.h.prepareMediaReturnSource(entry,()=>true,()=>true);
 assert.deepEqual(t.events[0],['rect',0],'WaterFlow indexes its reordered entries without list spacer');
 t=make();t.h.fileViewMode='waterfall';let prepared=false;
 t.h.ensureWaterfallIndex=async()=>{prepared=true};t.h.waterfallLocalIndex=i=>prepared?i:-1;
 assert.equal(await t.h.prepareMediaReturnSource(entry,()=>true,()=>prepared),true,'prepare target group before native return positioning');
 t=make();t.h.fileViewMode='waterfall';let cancelled=false;t.h.ensureWaterfallIndex=async()=>{cancelled=true};
 assert.equal(await t.h.prepareMediaReturnSource(entry,()=>!cancelled,()=>true),false,'cancelled group preparation cannot position another page');
 t=make();t.h.showSearch=true;await t.h.prepareMediaReturnSource(entry,()=>true,()=>true);
 assert.deepEqual(t.events[0],['index',2,false,3],'search reuses image AUTO alignment and spacer');
 t=make();t.h.fileViewMode='grid';assert.equal(await t.h.prepareMediaReturnSource(entry,()=>true,()=>true),true);
 assert.equal(await t.h.prepareMediaReturnSource(entry,()=>true,()=>false),false);
 assert.equal(t.events.length,0,'grid uses existing target geometry or fade; no file-grid relocation');
 t=make();t.setRect(undefined);let mounted=false,frames=0;
 t.h.fileListScroller.scrollToIndex=(i,anim,align)=>{t.events.push(['index',i,anim,align]);mounted=true};
 t.h.nextRenderFrame=async()=>{frames++};
 assert.equal(await t.h.prepareMediaReturnSource(entry,()=>true,()=>mounted),true);assert.equal(frames,1);
 await new Promise(r=>setTimeout(r,70));assert.equal(t.events.filter(e=>e[0]==='index').length,1,'completed preparation cancels its delayed lazy-item scroll');
 t=make();t.setRect(undefined);let rowY=0;
 t.h.fileListScroller.scrollToIndex=(i,anim,align)=>{t.events.push(['index',i,anim,align]);rowY=60;t.setRect({y:rowY,height:60})};
 t.h.fileListScroller.scrollBy=(x,y)=>{t.events.push(['by',x,y]);rowY-=y;t.setRect({y:rowY,height:60})};
 assert.equal(await t.h.prepareMediaReturnSource(entry,()=>true,()=>rowY>=94),true);
 assert.deepEqual(t.events.find(e=>e[0]==='by'),['by',0,-34],'a newly mounted row needs its fresh rect corrected before the return flight');
 t=make();t.setRect(undefined);let active=true;t.h.nextRenderFrame=async()=>{active=false};
 assert.equal(await t.h.prepareMediaReturnSource(entry,()=>active,()=>true),false);
 await new Promise(r=>setTimeout(r,70));assert.equal(t.events.filter(e=>e[0]==='index').length,1,'navigation cancellation cannot scroll the next page');
 t=make();let attempts=0;t.h.nextRenderFrame=async()=>{attempts++};
 assert.equal(await t.h.prepareMediaReturnSource(entry,()=>true,()=>false),false);assert.equal(attempts,8,'unavailable targets have a bounded fallback');
 t=make();assert.equal(await t.h.prepareMediaReturnSource({path:'/missing'},()=>true,()=>true),false);
 assert.equal(t.events.length,0,'missing file is not located by a guessed index');
 console.log('PASS: shared image/audio return — retain viewport, minimal top/bottom movement, list/WaterFlow/search indexes, stationary grid, lazy mount, bounded wait, cancelled callbacks and first-gesture protection.');
}
run().catch(e=>{console.error(e);process.exitCode=1});

const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require(process.argv[2]);
const source=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
function method(name){const a=source.search(new RegExp('^  private (?:async )?'+name+'\\(','m'));assert.ok(a>=0,name);const b=source.slice(a+1).search(/^  (?:private |@Builder)/m);return source.slice(a,a+b+1)}
const names=['publishWaterfallBatch','cloneDirectoryViewState','updateFilePageSize','updateWaterfallViewportWidth','canAnchorWaterfallViewport','rememberWaterfallViewportAnchor','restoreWaterfallViewport','captureFileViewAnchor','restoreFileViewAnchor','waitForFileViewport','updateWaterfallLayout','waterfallColumnCount','syncWaterfallScrollOrigin','waterfallBoundaryOffset','prefetchWaterfallRange','gateWaterfallScroll'];
const ex={};vm.runInNewContext(ts.transpileModule('export class Page {\n'+names.map(method).join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:ex,console,setTimeout,LengthMetrics:{vp:n=>n},ScrollAlign:{START:0},ScrollSource:{DRAG:0},WaterfallBatchCoordinator:{SIZE:12,MAX_RESIDENT_GROUPS:4},IMAGE_RETURN_MOUNT_FRAME_LIMIT:8});
const evictMatch=source.match(/canEvict: (\(entries: FileEntry\[\]\): boolean =>[\s\S]*?),\s*changed:/);assert.ok(evictMatch);
// Execute the actual delegate expression with an instance receiver.
const evictionMethod=evictMatch[1].replace('(entries: FileEntry[]): boolean =>','allowed(entries: FileEntry[]): boolean { return (')+' ) }';
const ev={};vm.runInNewContext(ts.transpileModule('export class E { '+evictionMethod+' }',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:ev});
function harness(){
 const p=new ex.Page(),frames=[],jumps=[],geometry=[],residents=new Set([46,47,48,49]);let nativeWidth=1440, nativeHeight=960,offset=7800,itemY=-20;
 const entries=Array.from({length:720},(_,i)=>({path:'/camera/'+i,isDirectory:false,ratio:[.75,1.33,.5,2][i%4]}));
 Object.assign(p,{screen:'files',fileViewMode:'waterfall',showSearch:false,showImageViewer:false,viewerClosePending:false,viewerBlocksFileContent:false,fileTransitionHeader:null,
 pageWidthVp:1440,pageHeightVp:960,fileViewportVersion:0,fileContentTouchActive:false,gridViewportAnchor:null,gridViewportRestore:null,waterfallViewportAnchor:null,waterfallResizeVersion:-1,waterfallViewportAnchorLocked:false,waterfallAnchorRestoreToken:4,waterfallLayoutWidth:1440,waterfallScrollOrigin:0,waterfallBatchEpoch:0,waterfallEntries:entries,entries,
 waterfallVisibleStartIndex:565,waterfallVisibleEndIndex:580,waterfallLayoutCount:0,waterfallColumnTails:new Map(),waterfallGroupTops:new Map(),waterfallGroupBottoms:new Map(),waterfallLayoutHeight:0,
 fileScrollViewport:{height:1440},floatingBarContentInset:()=>88,waterfallEdgePull:{holding:()=>false},canPullWaterfallEdge:()=>true,canAnchorGridViewport:()=>false,audioPlaybackUiVisible:()=>false,videoPlaybackUiVisible:()=>false,isImage:()=>true,
 nextRenderFrame:()=>new Promise(r=>frames.push(r)),cancelWaterfallPull(){this.pullsCancelled=(this.pullsCancelled||0)+1},effectivePageWidth:()=>p.pageWidthVp,waterfallContentTopInset:()=>90,waterfallAspectRatio:e=>e.ratio,
 getUIContext:()=>({px2vp:n=>n,getComponentUtils:()=>({getRectangleById:()=>({size:{width:nativeWidth,height:nativeHeight}})})}),
 waterfallLocalIndex:i=>residents.has(Math.floor(i/12))?i-39*12:-1,ensureWaterfallIndex:()=>assert.fail('rotation must not download or admit groups'),
 waterfallBatches:{first:39,residentFirst:()=>46,residentLast:()=>49,published:()=>entries.slice(39*12,50*12),setHidden:()=>geometry.push('hidden'),visible:(a,b)=>geometry.push([a,b])},
 waterfallScroller:{getItemRect:i=>({y:itemY,height:300}),currentOffset:()=>({yOffset:offset}),scrollToIndex(i,smooth,align,options){jumps.push({i,extra:options?.extraOffset});p.waterfallVisibleStartIndex=i+39*12;itemY=-(options?.extraOffset||0);offset+=500}},
 });p.updateWaterfallLayout(true);p.rememberWaterfallViewportAnchor();
 return{p,frames,jumps,geometry,entries,setOffset:n=>{offset=n},native(w,h){nativeWidth=w;nativeHeight=h},async flush(){for(let i=0;i<16;i++){frames.splice(0).forEach(r=>r());await Promise.resolve()}}};
}
(async()=>{
 // Prepending an older group must retain the current picture at the same visual Y.
 for(const y of [-400,135]){
  const p=new ex.Page(),jumps=[],entries=Array.from({length:24},(_,i)=>({path:'/prepend/'+i}));
  Object.assign(p,{fileViewMode:'waterfall',waterfallVisibleStartIndex:12,waterfallEntries:entries,waterfallPublishedFirst:1,waterfallBatchEpoch:0,
   waterfallBatches:{first:0,last:1,published:()=>entries,residentGroups:()=>[],residentFirst:()=>0,residentLast:()=>1},waterfallDataSource:{totalCount:()=>12,prepend:a=>assert.equal(a.length,12)},
   updateWaterfallLayout:()=>{},cancelWaterfallPull:()=>{},waterfallScroller:{getItemRect:()=>({y}),scrollToIndex:(i,_,__,o)=>jumps.push({i,y:-o.extraOffset})}});
  p.publishWaterfallBatch('prepend');assert.deepEqual(jumps,[{i:12,y}], 'prepend keeps both deeply cropped and below-header anchors in place');
 }
 const guard=new ev.E();Object.assign(guard,{waterfallResizeVersion:2,waterfallVisiblePaths:{},imageVisualStates:{}});assert.equal(guard.allowed([{path:'/anchor'}]),false,'pending preparation cannot evict the anchor while native visibility is transient');guard.waterfallResizeVersion=-1;assert.equal(guard.allowed([{path:'/anchor'}]),true);guard.waterfallVisiblePaths['/anchor']=true;guard.imageVisualStates['/anchor']={thumbnailSurface:'waterfall',thumbnailVisibleRatio:1};assert.equal(guard.allowed([{path:'/anchor'}]),false);
 let t=harness(),a=t.p.waterfallViewportAnchor;assert.equal(a.path,'/camera/565');
 const offscreen=harness();offscreen.p.waterfallScroller.getItemRect=i=>i===565-468?{y:-400,height:300}:{y:-50,height:300};offscreen.p.rememberWaterfallViewportAnchor();assert.equal(offscreen.p.waterfallViewportAnchor.path,'/camera/566','a fully offscreen sliding-window tail cannot become the rotation anchor');
 // Native columns can change before JS receives its size callback. Never save the resulting retired range.
 t.native(960,1440);t.p.waterfallVisibleStartIndex=516;t.p.rememberWaterfallViewportAnchor();assert.equal(t.p.waterfallViewportAnchor,a);
 t.p.updateFilePageSize(960,1440);assert.equal(t.p.waterfallResizeVersion,1);assert.equal(t.p.waterfallLayoutWidth,960);assert.equal(t.p.waterfallColumnWidthVp,(960-20-16)/3,'decoder and masonry share the new column width even when the child area callback ran first');assert.ok([...t.p.waterfallColumnTails.values()].every(v=>v.length===3),'bounds use portrait width and portrait columns together');
 t.p.prefetchWaterfallRange(516,533);assert.equal(t.geometry.length,0,'transient retired native range cannot alter resource focus');assert.equal(t.p.gateWaterfallScroll(-500,6).offsetRemain,-500,'resize restoration bypasses old pixel gate');
 await t.flush();assert.equal(t.p.waterfallResizeVersion,-1);assert.ok(t.jumps.length>0 && t.jumps.length<=2);assert.ok(t.jumps.every(j=>j.i===565-468));assert.ok(Math.abs(t.jumps[0].extra - 20/300*t.p.waterfallColumnWidthVp/t.p.waterfallAspectRatio(t.entries[565]))<.001,'preserve clipped image fraction with the correct scroll offset sign');assert.equal(t.p.waterfallVisibleStartIndex,565);assert.equal(t.p.waterfallEntries,t.entries);
 t.p.waterfallVisibleStartIndex=561;t.p.rememberWaterfallViewportAnchor();assert.equal(t.p.waterfallViewportAnchor,a,'new leading lane is not a new semantic anchor during repeated rotations');
 t.p.waterfallViewportAnchorLocked=false;t.p.rememberWaterfallViewportAnchor();assert.equal(t.p.waterfallViewportAnchor.path,'/camera/561','a real user gesture releases the rotation anchor');
 assert.equal(t.geometry.length,2,'restore explicitly resumes a pending group even if native emits no further callbacks');t.p.prefetchWaterfallRange(565,580);assert.equal(t.geometry.length,4,'normal group bookkeeping resumes after restore');
 // Rotation changes WaterFlow's estimated scroll origin; first input must still move.
 t.setOffset(23889);t.p.waterfallViewportAnchorLocked=false;t.p.waterfallVisibleStartIndex=565;t.p.syncWaterfallScrollOrigin(565,-20);const gate=t.p.gateWaterfallScroll(80,0);assert.ok(gate.offsetRemain>0,'native estimated offset and model group bounds must be calibrated before first swipe');
 // List return uses the same helper and must preserve its positive visual Y as well.
 const list=harness();list.p.fileViewMode='list';list.p.fileListScroller={scrollToIndex(i,_,__,o){list.jumps.push({i,extra:o.extraOffset})}};list.p.restoreFileViewAnchor({path:'/camera/565',y:75},4,0,0);assert.equal(list.jumps[0].i,566);assert.equal(list.jumps[0].extra,-75);
 const snapshot={mode:'waterfall',offset:{xOffset:0,yOffset:5000},anchor:{path:'/camera/565',y:-1100,clippedFraction:.58}};const cloned=list.p.cloneDirectoryViewState(snapshot);assert.equal(cloned.anchor.clippedFraction,.58);assert.notEqual(cloned.anchor,snapshot.anchor,'directory snapshots preserve crop without sharing mutable anchor state');
 // A very long image must retain a deep crop, rather than jumping backward many pictures.
 const long=harness();long.entries[565].ratio=.15;long.p.waterfallColumnWidthVp=300;const deep={path:'/camera/565',y:-1100,clippedFraction:.58};long.p.restoreFileViewAnchor(deep,4,0,0);assert.equal(long.jumps[0].extra,1160);long.p.waterfallColumnWidthVp=600;long.p.restoreFileViewAnchor(deep,4,0,0);assert.equal(long.jumps[1].extra,2320);
 // Only the latest viewport can restore, including a height-only follow-up callback.
 t=harness();a=t.p.waterfallViewportAnchor;t.native(960,1440);t.p.updateFilePageSize(960,1440);t.native(1440,960);t.p.updateFilePageSize(1440,960);await t.flush();assert.equal(t.p.waterfallResizeVersion,-1);assert.ok(t.jumps.length<=2);assert.equal(t.p.waterfallViewportAnchor,a);
 // Real touch, navigation and media overlays cancel the pending restore, with no late scroll.
 for(const cancel of [p=>{p.waterfallResizeVersion=-1;p.waterfallAnchorRestoreToken++},p=>{p.screen='settings'},p=>{p.showImageViewer=true}]){
  t=harness();t.native(960,1440);t.p.updateFilePageSize(960,1440);cancel(t.p);await t.flush();assert.equal(t.jumps.length,0);assert.equal(t.p.waterfallResizeVersion,-1);
 }
 // Starting a rotation behind a Viewer does not reposition the hidden file page.
 t=harness();t.p.showImageViewer=true;t.native(960,1440);t.p.updateFilePageSize(960,1440);await t.flush();assert.equal(t.jumps.length,0);
 // An old nonresident callback cannot replace the last stable identity even at the same size.
 t=harness();a=t.p.waterfallViewportAnchor;t.p.waterfallVisibleStartIndex=516;t.p.waterfallVisibleEndIndex=533;t.p.rememberWaterfallViewportAnchor();assert.equal(t.p.waterfallViewportAnchor,a);
 t.p.waterfallVisibleStartIndex=551;t.p.waterfallVisibleEndIndex=562;t.p.rememberWaterfallViewportAnchor();assert.equal(t.p.waterfallViewportAnchor.path,'/camera/552','interleaved retired tail must not leave an obsolete evicted anchor');
 console.log('PASS waterfall resize: retired placeholders, consistent column bounds, latest identity, bounded restore, resource preservation, touch/navigation/Viewer cancellation');
})().catch(e=>{console.error(e);process.exitCode=1});

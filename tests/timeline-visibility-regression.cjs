const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require(process.argv[2]);
function load(source,bindings={}){const exports={};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports,...bindings});return exports}
const {FileGridLayout}=load(fs.readFileSync('entry/src/main/ets/ui/FileGridLayout.ets','utf8'));
const {DirectoryTimeline,DirectoryTimelinePolicy}=load(fs.readFileSync('entry/src/main/ets/model/DirectoryTimeline.ets','utf8'),{require:()=>({FileEntry:class{}})});
const source=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
function method(name){const a=source.search(new RegExp('^  private '+name+'\\(','m'));assert.ok(a>=0,name);const b=source.slice(a+1).search(/^  (?:private |@Builder)/m);return source.slice(a,a+b+1)}
const {Page}=load('export class Page {\n'+['shouldShowTimeline','timelineViewportImageCapacity','fileGridColumnCount'].map(method).join('\n')+'\n}',{FileGridLayout,DirectoryTimelinePolicy});
function page(width=400,height=800,count=120){const p=new Page(),timeline=new DirectoryTimeline();Object.assign(timeline,{complete:true,directImageCount:count,earliestTime:Date.UTC(2025,0,1),latestTime:Date.UTC(2025,2,1)});const entries=Array.from({length:count},()=>({isDirectory:false}));Object.assign(p,{pageWidthVp:width,pageHeightVp:height,fileSortKey:'time',showPageTransition:false,currentRootType:3,currentPath:'/photos',indexedDirectoryKey:'3:/photos',directoryTimeline:timeline,floatingTimelineHeight:()=>400,shouldShowFileToolsBar:()=>true,isImage:()=>true,entries,waterfallEntries:entries,fileVisibleStartIndex:0,fileVisibleEndIndex:31,waterfallVisibleStartIndex:0,waterfallVisibleEndIndex:11});return p}
// Same directory/window: one prepared group or a large photo must not lower
// the shared six-screen threshold merely because fewer nodes are visible.
const p=page();for(const mode of ['grid','list','waterfall']){p.fileViewMode=mode;assert.equal(p.shouldShowTimeline(),false,mode+' must reject this 120-photo directory in the same window')}
for(const [w,h] of [[400,800],[960,1440],[1440,960],[700,700],[400,500]]){
 const p=page(w,h,5000);for(const mode of ['grid','list','waterfall']){p.fileViewMode=mode;for(const count of [0,1,12,48,200]){p.fileVisibleEndIndex=count;p.waterfallVisibleEndIndex=count;assert.equal(p.shouldShowTimeline(),true)}}
 const threshold=DirectoryTimelinePolicy.minimumImageCount(p.timelineViewportImageCapacity());
 for(const mode of ['grid','list','waterfall']){p.fileViewMode=mode;p.directoryTimeline.directImageCount=threshold-1;assert.equal(p.shouldShowTimeline(),false);p.directoryTimeline.directImageCount=threshold;assert.equal(p.shouldShowTimeline(),true)}
 p.directoryTimeline.directImageCount=79;assert.equal(p.shouldShowTimeline(),false,'absolute 80-image floor');
 p.directoryTimeline.directImageCount=5000;p.directoryTimeline.complete=false;assert.equal(p.shouldShowTimeline(),false);p.directoryTimeline.complete=true;
 p.directoryTimeline.latestTime=p.directoryTimeline.earliestTime+29*86400000;assert.equal(p.shouldShowTimeline(),false);p.directoryTimeline.latestTime=p.directoryTimeline.earliestTime+30*86400000;assert.equal(p.shouldShowTimeline(),true);
 for(const sort of ['name','type','size']){p.fileSortKey=sort;assert.equal(p.shouldShowTimeline(),false)}p.fileSortKey='time';
 p.indexedDirectoryKey='3:/other';assert.equal(p.shouldShowTimeline(),false);p.indexedDirectoryKey='3:/photos';
 p.showPageTransition=true;assert.equal(p.shouldShowTimeline(),false);p.showPageTransition=false;
 p.shouldShowFileToolsBar=()=>false;assert.equal(p.shouldShowTimeline(),false);p.shouldShowFileToolsBar=()=>true;
 p.floatingTimelineHeight=()=>0;assert.equal(p.shouldShowTimeline(),false);
}
const bounded=page(400,800,5000);const unreadable=new Proxy([],{get(){throw new Error('eligibility must not scan or inspect directory/visible image arrays')}});bounded.entries=bounded.waterfallEntries=unreadable;bounded.isImage=()=>assert.fail('no per-entry type checks');for(const mode of ['grid','list','waterfall']){bounded.fileViewMode=mode;assert.equal(bounded.shouldShowTimeline(),true)}
for(const value of [0,-1,NaN,Infinity]){const p=page(value,800,5000);assert.equal(p.shouldShowTimeline(),false,'invalid layout cannot transiently enable a timeline')}
console.log('PASS timeline visibility: same directory/window across all modes, batch/scroll invariance, count/span/completeness/sort/window and directory guards');

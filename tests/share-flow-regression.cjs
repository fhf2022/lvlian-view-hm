const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require(process.argv[2]);
const source=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
function method(name){const a=source.search(new RegExp('^  private (?:async )?'+name+'\\(','m'));assert.ok(a>=0,name);const b=source.slice(a+1).search(/^  (?:private |@Builder)/m);return source.slice(a,a+b+1)}
const shows=[],pins=new Map(),ex={};
class Data{constructor(record){this.records=[record]}addRecord(record){this.records.push(record)}}
const utd={UniformDataType:{FOLDER:'general.folder',FILE:'general.file',IMAGE:'general.image',VIDEO:'general.video',AUDIO:'general.audio'},getUniformDataTypeByFilenameExtension:ext=>'type:'+ext};
vm.runInNewContext(ts.transpileModule('export class Sharing {\n'+[
  'shareEntry','shareSelectedEntries','shareEntries','preparedShareData','shareRecord','shareUtd','hasGestureShareContent','selectionCanShare','actionSupportsShare'
].map(method).join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
{exports:ex,systemShare:{SharedData:Data,ShareController:class{constructor(data){this.data=data}async show(context,options){shows.push({data:this.data,options})}},SelectionMode:{SINGLE:0,BATCH:2},SharePreviewMode:{DEFAULT:0}},
 utd,util:{TextEncoder:class{encodeInto(text){return Buffer.from(text)}}},Buffer,getContext:()=>({}),
 fileUri:{getUriFromPath:path=>'file://app'+path},StorageBudget:{pin:path=>pins.set(path,(pins.get(path)||0)+1),unpin:path=>pins.set(path,pins.get(path)-1)}});
const entry=(path,dir)=>({path,name:path.slice(path.lastIndexOf('/')+1),isDirectory:dir,clone(){return entry(path,dir)}});
const folder=entry('/nas/folder',true),file=entry('/nas/file.txt',false);
function make(){
 const p=new ex.Sharing();let scope='a',prepared=0,exits=0,errors=[];
 Object.assign(p,{isBusy:false,gestureSharePreparing:false,gestureSharePageVisible:true,abilityInBackground:false,continuationContextToken:1,
 repository:{sessionIdentity:()=>scope},selectedEntriesInCurrentDirectory:()=>[folder,file],gestureShareCandidates:()=>[folder],
 closeImageMoreMenu(){},closeSelectionMoreMenu(){},confirmMeteredSelection:async()=>true,
 prepareShareEntries:async(entries,owned,valid,metered)=>{prepared++;assert.ok(valid());assert.equal(metered,true);pins.set('/cache/file',1);owned.push('/cache/file');const mixed=entries.some(e=>e.isDirectory);return {entries,localPaths:{[folder.path]:'/public/folder',[file.path]:mixed?'/public/file.txt':'/cache/file'},sharedUris:mixed?{[folder.path]:'file://docs/folder',[file.path]:'file://docs/file.txt'}:{},failedCount:0,skippedCount:0}},
 gestureShareThumbnailUri:()=>'',fileExtension:name=>name.includes('.')?name.split('.').pop():'',fileType:()=> '文件',isImage:()=>false,isVideo:()=>false,isAudio:()=>false,
 exitSelectionMode(){exits++},reportError(error){errors.push(error.message)},showImmersiveToast(text){errors.push(text)}});
 return {p,scope:value=>scope=value,stats:()=>({prepared,exits,errors})};
}
(async()=>{
 let h=make();assert.equal(h.p.hasGestureShareContent(),true,'a folder selection registers the gesture path');assert.equal(h.p.selectionCanShare(),true);
 await h.p.shareSelectedEntries();assert.equal(shows.length,1);assert.equal(shows[0].options.selectionMode,2);assert.equal(h.stats().exits,1);
 assert.deepEqual(shows[0].data.records.map(r=>r.uri),['file://docs/folder','file://docs/file.txt']);
 assert.equal(shows[0].data.records[0].utd,'general.folder');assert.equal(shows[0].data.records[1].title,'file.txt');
 h=make();await h.p.shareEntry(folder);assert.equal(shows.length,2);assert.equal(shows[1].options.selectionMode,0);assert.equal(h.stats().exits,0);
 h=make();let resolve;h.p.confirmMeteredSelection=()=>new Promise(r=>resolve=r);
 const held=h.p.shareEntries([folder]);await Promise.resolve();await h.p.shareEntries([file]);assert.equal(h.stats().prepared,0,'pending confirmation owns its busy state');
 h.scope('b');resolve(true);await held;assert.equal(h.stats().prepared,0,'changed accounts cannot continue the captured request');assert.equal(h.p.isBusy,false);
 h=make();h.p.confirmMeteredSelection=async()=>false;await h.p.shareEntries([folder]);assert.equal(h.stats().prepared,0);assert.equal(h.p.isBusy,false);
 h=make();h.p.prepareShareEntries=async()=>({entries:[folder],localPaths:{[folder.path]:'/public/folder'},sharedUris:{[folder.path]:'file://docs/folder'}});
 await h.p.shareEntries([folder,file]);assert.equal(shows.length,2,'normal mixed sharing never silently submits a subset');assert.match(h.stats().errors[0],/未准备完成/);
 h=make();assert.throws(()=>h.p.preparedShareData({entries:[folder],localPaths:{[folder.path]:'/public/folder'},sharedUris:{[folder.path]:'file://docs/'+'x'.repeat(190*1024)}}),/减少本次选择/);
 h=make();await h.p.shareEntry(file);assert.equal(shows.length,3);assert.equal(shows[2].data.records[0].uri,'file://app/cache/file','pure files keep their original private-cache share route');
 assert.ok([...pins.values()].every(n=>n===0));
 console.log('PASS shared sharing: folder/menu/multiselect entry points, preserved document URI, ordinary files, batch mode, confirmation ownership, account cancellation, complete selection and IPC size guard');
})().catch(error=>{console.error(error);process.exitCode=1});

// node tests/file-drop-import-regression.cjs <SDK typescript.js>
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require(process.argv[2]);
const types={FILE_URI:'general.file-uri',FILE:'general.file',IMAGE:'general.image',VIDEO:'general.video',AUDIO:'general.audio',FOLDER:'general.folder'};
const channel={ProgressIndicator:{DEFAULT:1},ListenerStatus:{FINISHED:0,PROCESSING:1,CANCELED:2,INNER_ERROR:200}};
const native={'@kit.ArkData':{uniformTypeDescriptor:{UniformDataType:types},unifiedDataChannel:channel}};
function compile(source,globals={}){
 const exports={};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
 {exports,require:name=>native[name]||{},console,Math,Set,Error,Promise,...globals});return exports;
}
const {FileImport}=compile(fs.readFileSync('entry/src/main/ets/upload/FileImport.ets','utf8'));
const record=(uri,type=types.FILE_URI)=>({getTypes:()=>[type],getType:()=>type,getEntry:()=>({oriUri:uri,fileType:types.IMAGE}),uri});
const data=(...records)=>({getRecords:()=>records});
const modern=record('file://media/Photo/1');modern.getTypes=()=>[types.IMAGE,types.FILE_URI];
const parsed=FileImport.fromDrop(data(modern,record('file://media/Photo/1'),record('file://docs/a.pdf',types.FILE),
 record('https://example.invalid/a.jpg'),record('file://docs/caption.txt','general.plain-text')));
assert.deepEqual([...parsed.uris],['file://media/Photo/1','file://docs/a.pdf']);
assert.equal(parsed.unsupported,2);
assert.throws(()=>FileImport.fromDrop(data(record('file://docs/a','general.plain-text'))),/原文件/);
const folder=record('file://docs/folder');folder.getEntry=()=>({oriUri:'file://docs/folder',fileType:types.FOLDER});
assert.throws(()=>FileImport.fromDrop(data(folder)),/原文件/);
assert.throws(()=>FileImport.fromDrop({getRecords:()=>Array.from({length:501},()=>modern)}),/500/);

const page=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
const names=['canAcceptFileDrop','externalFileDrag','updateFileDropHover','receiveFileDrop','importDroppedFiles','finishDropImport','cancelDropImport'];
function method(name){
 const start=page.search(new RegExp('^  private (?:async )?'+name+'\\(','m'));assert.ok(start>=0,name);
 const end=page.slice(start+1).search(/^  (?:private |@Builder)/m);return page.slice(start,start+end+1);
}
const DragResult={DRAG_SUCCESSFUL:0,DRAG_FAILED:1,DROP_ENABLED:3,DROP_DISABLED:4};
const {Page}=compile('export class Page {\n'+names.map(method).join('\n')+'\n}',{
 FileImport,unifiedDataChannel:channel,DragResult,DragBehavior:{COPY:0},
 getContext:()=>({applicationInfo:{name:'cn.fhf.linkfiles'}})
});
function make(){
 const h=new Page(),calls=[],messages=[],errors=[],cancellations=[];
 Object.assign(h,{screen:'files',currentPath:'/home/fhf/temp/drop-target',offlineCacheMode:false,isBusy:false,isNavigating:false,
 showPageTransition:false,showSearch:false,selectionMode:false,importSelecting:false,continuationPending:false,continuationSending:false,
 continuationDialogCount:0,dropImportHover:false,dropImportActive:false,dropImportKey:'',dropImportGeneration:0,scope:'account-a',
 parentOverlayOwnsInteraction:()=>false,repository:{cacheScopeHash:()=>h.scope},ensureDownloadState:async()=>{},
 uploadQueue:{enqueue:async(uri,target,scope)=>{calls.push({uri,target,scope});return {status:'queued'};}},
 showImmersiveToast:text=>messages.push(text),reportError:error=>errors.push(error.message),
 getUIContext:()=>({getDragController:()=>({cancelDataLoading:key=>cancellations.push(key)})})});
 return {h,calls,messages,errors,cancellations};
}
function event(source='com.huawei.files',synchronous=false){
 const results=[];let options,loads=0;
 return {getDragSource:()=>source,setResult:value=>results.push(value),results,get options(){return options;},get loads(){return loads;},
 startDataLoading:value=>{options=value;loads++;if(synchronous)value.dataProgressListener({status:0,progress:100},data(modern));return 'udmf-key';}};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
 const batchCalls=[];
 const batch=await FileImport.enqueue({enqueue:async(uri,target,scope)=>{batchCalls.push([uri,target,scope]);if(uri==='b')throw Error('denied');return{status:uri==='c'?'failed':'queued'};}},
 ['a','b','c','d'],'/target','account',()=>true);
 assert.equal(batch.added,2);assert.equal(batch.failed,2);assert.equal(batchCalls.length,4);
 let current=true;
 const changed=await FileImport.enqueue({enqueue:async()=>{current=false;return{status:'queued'};}},['a','b','c'],'/target','account',()=>current);
 assert.equal(changed.added,1);assert.equal(changed.failed,2,'stop remaining imports after account change');

 let t=make(),e=event();t.h.updateFileDropHover(e);assert.equal(t.h.dropImportHover,true);
 t.h.receiveFileDrop(e);assert.equal(t.h.dropImportHover,false);assert.equal(t.h.importSelecting,true);
 assert.equal(e.loads,1);assert.equal(e.options.progressIndicator,1);assert.equal(e.options.destUri,undefined,'avoid a second unbudgeted staging copy');
 assert.equal(e.options.acceptableInfo.recordCount,501);
 t.h.currentPath='/home/fhf/other';
 e.options.dataProgressListener({status:0,progress:100},data(modern));await tick();
 assert.equal(t.calls[0].target,'/home/fhf/temp/drop-target','release position fixes destination before async data retrieval');
 assert.equal(t.calls[0].scope,'account-a');assert.equal(t.h.importSelecting,false);assert.equal(t.h.currentPath,'/home/fhf/other','do not navigate to transfers');
 e.options.dataProgressListener({status:0,progress:100},data(modern));await tick();assert.equal(t.calls.length,1,'duplicate completion cannot duplicate uploads');

 t=make();e=event();t.h.receiveFileDrop(e);t.h.scope='account-b';e.options.dataProgressListener({status:0,progress:100},data(modern));await tick();
 assert.equal(t.calls.length,0,'old grants cannot upload into another account');assert.equal(t.errors.length,1);assert.equal(t.h.importSelecting,false);

 t=make();e=event();t.h.receiveFileDrop(e);const rejected=event();t.h.receiveFileDrop(rejected);
 assert.equal(rejected.loads,0,'bound to one active receiving/staging batch');
 t.h.cancelDropImport();assert.deepEqual(t.cancellations,['udmf-key']);assert.equal(t.h.importSelecting,false);
 const newer=event();t.h.receiveFileDrop(newer);e.options.dataProgressListener({status:0,progress:100},data(modern));await tick();
 assert.equal(t.calls.length,0);assert.equal(t.h.importSelecting,true,'late callback cannot release the next import');
 newer.options.dataProgressListener({status:2,progress:-1},null);assert.equal(t.h.importSelecting,false);assert.equal(t.errors.length,0);

 t=make();e=event('com.huawei.photos',true);t.h.receiveFileDrop(e);await tick();
 assert.equal(t.calls.length,1);assert.equal(t.h.dropImportKey,'','synchronous completion cannot leave a stale cancellation key');

 for(const [key,value] of [['screen','settings'],['currentPath',''],['showSearch',true],['selectionMode',true],['isNavigating',true],['isBusy',true],
 ['continuationPending',true],['continuationSending',true],['offlineCacheMode',true],['showPageTransition',true],['continuationDialogCount',1]]){
  t=make();t.h[key]=value;e=event();t.h.receiveFileDrop(e);assert.equal(e.loads,0,key);assert.equal(e.results.at(-1),1,key);
 }
 t=make();t.h.parentOverlayOwnsInteraction=()=>true;e=event();t.h.receiveFileDrop(e);assert.equal(e.loads,0,'covered media/modals are not upload targets');
 t=make();e=event('cn.fhf.linkfiles');t.h.receiveFileDrop(e);assert.equal(e.loads,0,'internal media/selection drags must never re-upload NAS content');
 t=make();e=event();e.startDataLoading=()=>{throw Error('UDMF unavailable');};t.h.receiveFileDrop(e);assert.equal(t.h.importSelecting,false);assert.equal(t.errors.length,1);
 assert.ok(page.includes('.onDrop((event: DragEvent) => this.receiveFileDrop(event), { disableDataPrefetch: true })'));
 console.log('PASS: external file drop — modern/legacy URI grants, bounded records, copy-only, deduplication, captured destination/account, shared queue failures, cancellation/stale callbacks, synchronous UDMF completion and input isolation');
})().catch(error=>{console.error(error);process.exitCode=1;});

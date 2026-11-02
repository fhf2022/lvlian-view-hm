// Execute production grouping, queue metadata and video persistence with native services mocked.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const ts=require(process.argv[2]),native={};
function load(path){const ex={};vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/'+path+'.ets','utf8'),
 {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
 {exports:ex,require:name=>native[name]||{},Observed:value=>value,console,setTimeout,clearTimeout});return ex;}
native['@kit.ArkTS']={util:{generateRandomUUID:()=>crypto.randomUUID()}};
const model=load('model/FileEntry');native['../model/FileEntry']=model;
const {DownloadTaskRecord:Task,FileEntry}=model;
const grouping=load('transfer/TransferTaskGroup');native['../transfer/TransferTaskGroup']=grouping;
const {TransferBatch:Batch,TransferTaskGroups:Groups}=grouping;
function task(id,batch,size=100,status='queued',scope='a'){
 const t=new Task();Object.assign(t,{id,name:id+'.txt',remotePath:'/test/'+id,size,status,sourceScope:scope,createdAt:1,updatedAt:1});
 if(batch)Task.copyBatchInto(batch,t);return t;
}
const a=new Batch('文件夹','a'),b=new Batch('', 'a');
a.batchState=b.batchState='ready';
const small=task('small',a,100,'completed'),large=task('video:big',a,900,'downloading');large.receivedBytes=450;
const alone=task('single',null),selection=task('selected',b),groups=new Groups();
groups.update([small,large,alone,selection],false);
assert.equal(groups.rows.length,3);const folder=groups.rows[0];
assert.equal(folder.name,'文件夹');assert.ok(Math.abs(folder.percent-55)<1e-6,'aggregate by bytes, not mean file percentages');assert.equal(folder.tasks.length,2);
assert.equal(groups.rows[1].grouped,false);assert.equal(groups.rows[2].name,'1 个文件');
large.receivedBytes=600;groups.update([small,large,alone,selection],false);
assert.equal(groups.rows[0],folder,'progress preserves row object and expand state');assert.equal(folder.percent,70);
large.status='completed';large.batchState='adding';groups.update([small,large],false);assert.ok(folder.percent<100);assert.equal(folder.loading,true);
large.batchState='incomplete';groups.update([small,large],false);assert.ok(folder.percent<100);assert.match(folder.info,/未加入/);
large.batchState='ready';groups.update([small,large],false);assert.equal(folder.percent,100);
const sameName=new Batch('文件夹');sameName.batchState='ready';
groups.update([small,task('another',sameName),task('other-account',a,100,'paused','b')],false);
assert.equal(groups.rows.length,3,'distinct operations/accounts never merge by folder name');
const restored=new Task();Task.copyInto(JSON.parse(JSON.stringify(large)),restored);assert.equal(restored.batchId,a.batchId);
Task.copyInto({id:'old'},restored);assert.equal(restored.batchId,'','legacy record defaults to a single task');
const unknown=task('unknown',a,0,'downloading');groups.update([unknown],true);assert.equal(groups.rows[0].loading,true);
unknown.status='completed';groups.update([unknown],true);assert.equal(groups.rows[0].percent,100);
const failed=task('failed',a,100,'failed');groups.update([small,failed],false);assert.ok(groups.rows[0].percent<100);assert.match(groups.rows[0].info,/失败/);
const many=Array.from({length:5000},(_,i)=>task('many-'+i,a,2,'completed'));groups.update(many,false);
assert.equal(groups.rows.length,1);assert.equal(groups.rows[0].tasks.length,5000);assert.equal(groups.rows[0].size,10000);
// Retain/expire whole histories; active or interrupted batch siblings must not disappear.
many.forEach(t=>t.updatedAt=100);assert.equal(Task.retainHistory(many,1).length,5000);
assert.equal(Task.retainHistory(many,101).length,0);many[0].status='downloading';assert.equal(Task.retainHistory(many,101).length,5000);
const singles=Array.from({length:300},(_,i)=>{const t=task('history-'+i,null,1,'completed');t.updatedAt=i;return t});
assert.equal(Task.retainHistory(singles,0).length,200);

const values=new Map(),prefs={get:async(k,d)=>values.get(k)??d,put:async(k,v)=>values.set(k,v),flush:async()=>{}};
native['@kit.ArkData']={preferences:{getPreferences:async()=>prefs},uniformTypeDescriptor:{UniformDataType:{}}};
native['@kit.AbilityKit']={};
const mediaStore=load('media/MediaLocalStore');native['./MediaLocalStore']=mediaStore;
native['../download/DownloadDestination']={DownloadDestination:{directory:async()=>'/downloads'}};
native['../transfer/TransferBackgroundManager']={TransferBackgroundManager:{shared:()=>({requestResume:async()=>{}})}};
native['./ByteRangeStore']=load('media/ByteRangeStore');
const {VideoTransferManager:Video}=load('media/VideoTransferManager');
const {DownloadQueueManager:Queue}=load('download/DownloadQueueManager');
const {FileImport}=load('upload/FileImport');
(async()=>{
 const q=Object.create(Queue.prototype);Object.assign(q,{stagingDirectory:'/queue',repository:{cacheScopeHash:()=> 'a'},preferencesStore:prefs,notify(){}});
 const inProgress=task('restore',new Batch('目录','a'));inProgress.sourceKey='version';
 q.loadTasks(JSON.stringify([inProgress]));assert.equal(q.tasks[0].batchState,'incomplete','interrupted enumeration cannot look complete after restart');
 await q.finishBatch(inProgress.batchId,true);assert.equal(q.tasks[0].batchState,'ready');
 assert.equal(JSON.parse(values.get('download_tasks_v1'))[0].batchId,inProgress.batchId);
 const store=new mediaStore.MediaLocalStore();await store.initialize({},'a');
 const batchedStore=new mediaStore.MediaLocalStore();await batchedStore.initialize({},'bulk');
 const manyVideoBatch=new Batch('许多视频','a');
 for(let i=0;i<300;i++){const r=new mediaStore.MediaLocalRecord();r.sourceKey='bulk-'+i;Task.copyBatchInto(manyVideoBatch,r);batchedStore.put(r)}
 let publications=0;batchedStore.onChange(()=>publications++);
 assert.equal(batchedStore.finishBatch(manyVideoBatch.batchId,true),true);
 assert.equal(publications,1,'finishing a large video batch publishes once');
 assert.equal(batchedStore.finishBatch(manyVideoBatch.batchId,true),false);assert.equal(publications,1);
 await batchedStore.flush();
 const video=Object.create(Video.prototype),entry=new FileEntry();Object.assign(entry,{path:'/test/movie.mp4',name:'movie.mp4',size:100,modifiedTime:1});
 const signature=new mediaStore.RemoteFileSignature('a',entry.path,100,1);
 const session={sourceKey:signature.key(),signature,entry,descriptor:{etag:'',checksum:''},lastPersistAt:0,
 cachePath:'/cache/movie',partPath:'/stage/movie.part',durablePath:'',relativePath:'文件夹/movie.mp4',totalBytes:100,
 downloadRequested:false,temporaryOnly:false,paused:false,waitingStatus:'',ranges:{coveredBytes:()=>40,serialize:()=>['0-40']},
 batchId:'',batchName:'',batchKind:'files',batchState:'ready'};
 Object.assign(video,{store,taskRows:new Map(),states:{},sessions:new Map([[signature.key(),session]]),stagingDirectory:'/stage',ready:true,
 repository:{cacheScopeHash:()=> 'a',signatureForFile:()=>signature},networkPolicy:{isMetered:()=>false},notify(){},requireInitialized:async()=>{},resolveLocal:async()=>'',getSession:async()=>session});
 video.startDownload=async s=>{s.downloadRequested=true;s.downloadPromise=Promise.resolve();video.persistSession(s)};
 const vb=new Batch('文件夹','a');await video.requestDownload(entry,'/downloads','文件夹/movie.mp4',vb);
 assert.equal(store.find(signature.key()).batchId,vb.batchId);assert.equal(video.snapshotTasks()[0].batchId,vb.batchId);
 await video.requestDownload(entry,'/downloads','文件夹/movie.mp4',new Batch('另一个目录','a'));
 assert.equal(session.batchId,vb.batchId,'deduplicated active videos retain original batch membership');
 await video.finishBatch(vb.batchId,true);assert.equal(store.find(signature.key()).batchState,'ready');
 const again=new mediaStore.MediaLocalStore();await again.initialize({},'a');assert.equal(again.find(signature.key()).batchId,vb.batchId);
 video.store=again;video.sessions=new Map();video.resolveLocal=async()=>'/cache/movie';video.isDurablePath=()=>false;video.fileSize=()=>100;
 let promoted;video.startDownload=async s=>{promoted=s};const promotedBatch=new Batch('缓存视频','a');
 await video.requestDownload(entry,'/downloads','缓存视频/movie.mp4',promotedBatch);assert.equal(promoted.batchId,promotedBatch.batchId,'cache promotion also carries batch metadata');
 const batches=[],finishes=[];
 const fakeQueue={enqueue:async(uri,target,scope,batch)=>{batches.push(batch);return{status:uri==='bad'?'failed':'queued'}},finishBatch:async(id,ok)=>finishes.push({id,ok})};
 await FileImport.enqueue(fakeQueue,['first','bad','last'],'/target','a',()=>true);
 assert.equal(new Set(batches.map(b=>b.batchId)).size,1);assert.equal(finishes[0].ok,true,'admitted failed tasks can be retried to complete the batch');
 const missingQueue={...fakeQueue,enqueue:async()=>{throw new Error('missing original')}};
 await FileImport.enqueue(missingQueue,['missing','missing2'],'/target','a',()=>true);
 assert.equal(finishes[1].ok,false,'files without a task leave the batch incomplete');
 batches.length=0;await FileImport.enqueue(fakeQueue,['single'],'/target','a',()=>true);assert.equal(batches[0],null);
 console.log('PASS transfer aggregation: byte weighting, stable rows, mixed videos/files, independent batches/accounts, adding/incomplete/unknown/failed states, legacy records, whole-group retention, durable video metadata/cache promotion, upload batch identity and single-file fallback');
})().catch(e=>{console.error(e);process.exitCode=1});

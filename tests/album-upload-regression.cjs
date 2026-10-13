const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert/strict');
const { DatabaseSync } = require('node:sqlite');
const ts = require(process.argv[2] || 'typescript');
const root = process.cwd(), testRoot = path.join(root, 'temp/album-upload/host-fixture');
fs.mkdirSync(testRoot, {recursive:true});
const models = {}, modules = new Map(), databases = new Map();
const budget = { pin(){}, unpin(){}, sync(){}, admit(p,n){ if(n>32*1024*1024) throw Error('cache too large'); },
  removeWhenUnused(p){try{fs.unlinkSync(p)}catch{}} };
let nasOnline = true, nasListeners=[];
let foreground=true, protectedTransfer=false;
const protection={canRun:()=>foreground||protectedTransfer,onChange(){},onCancel(){},requestResume(){},update(){}};
const nas={canRequest:()=>nasOnline,current:()=>nasOnline?'online':'unavailable',onChange:f=>nasListeners.push(f),retryNow:async()=>{}};
const fileIo={OpenMode:{READ_ONLY:fs.constants.O_RDONLY,CREATE:fs.constants.O_CREAT,READ_WRITE:fs.constants.O_RDWR,TRUNC:fs.constants.O_TRUNC},
  accessSync:p=>fs.existsSync(p),mkdirSync:p=>fs.mkdirSync(p),listFileSync:p=>fs.readdirSync(p),
  openSync:(p,flags)=>({fd:fs.openSync(p,flags)}),open:async(p,flags)=>({fd:fs.openSync(p,flags)}),closeSync:f=>fs.closeSync(typeof f==='number'?f:f.fd),
  stat:async fd=>{const s=fs.fstatSync(fd);return {size:s.size,mtime:s.mtimeMs}},
  read:async(fd,b,opt)=>{await new Promise(r=>setImmediate(r));return fs.readSync(fd,Buffer.from(b),0,b.byteLength,opt.offset)},
  writeSync:(fd,b,opt)=>fs.writeSync(fd,Buffer.from(b),0,opt.length,opt.offset)};
function rdb(config){
  if(databases.has(config.name))return databases.get(config.name);
  const db=new DatabaseSync(':memory:');
  const wrapper={executeSql:async(sql,args=[])=>{db.prepare(sql).run(...args)},querySql:async(sql,args=[])=>{
    const rows=db.prepare(sql).all(...args), cols=rows.length?Object.keys(rows[0]):[], r={i:-1,goToNextRow(){return ++this.i<rows.length},
      getColumnIndex:c=>cols.indexOf(c), getString(i){return String(rows[this.i][cols[i]]??'')},getLong(i){return Number(rows[this.i][cols[i]])},close(){}};return r;
  }};databases.set(config.name,wrapper);return wrapper;
}
const mocks={'@kit.ArkData':{relationalStore:{getRdbStore:async(ctx,c)=>rdb(c),SecurityLevel:{S2:2}}},'@kit.AbilityKit':{},
 '@kit.CoreFileKit':{fileIo},'@kit.ArkTS':{util:{generateRandomUUID:()=>require('crypto').randomUUID()}},
 '@kit.ArkUI':{window:{getLastWindow:async()=>({setWindowKeepScreenOn:async()=>{}})}},
 '../download/StorageBudget':{StorageBudget:budget},'../core/network/NasConnection':{NasConnection:{shared:()=>nas}},
 './LocalAlbumSource':{LocalAlbumSource:class{}}};
mocks['../transfer/TransferBackgroundManager']={TransferBackgroundManager:{shared:()=>protection}};
function load(relative){
 const full=path.join(root,relative); if(modules.has(full))return modules.get(full);
 const code=ts.transpileModule(fs.readFileSync(full,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 const module={exports:{}}; modules.set(full,module.exports);
 const req=name=>mocks[name]||(name.startsWith('.')?load(path.relative(root,path.resolve(path.dirname(full),name+'.ets'))):{});
 vm.runInThisContext('(function(require,module,exports){'+code+'\n})',{filename:full})(req,module,module.exports);return module.exports;
}
const {AlbumUploadPolicy,AlbumUploadItem,LocalImageAlbum}=load('entry/src/main/ets/upload/AlbumUploadModel.ets');
const {AlbumUploadStore}=load('entry/src/main/ets/upload/AlbumUploadStore.ets');
const {AlbumUploadManager}=load('entry/src/main/ets/upload/AlbumUploadManager.ets');
const {UgreenError,UgreenErrorKind}=load('entry/src/main/ets/ugreen/UgreenErrors.ets');
let scenarios=[];
const report=(name)=>{scenarios.push(name);console.log('PASS '+name)};
function image(name,size,seed){const item=new AlbumUploadItem();item.id=require('crypto').randomUUID();item.name=name;item.size=size;item.modified=1000;
 item.uri=path.join(testRoot,item.id);fs.writeFileSync(item.uri,Buffer.alloc(size,seed));return item}
const context={filesDir:testRoot};
function source(items){return {snapshot:async(album,consume,check)=>{for(let i=0;i<items.length;i+=200){check();await consume(items.slice(i,i+200).map(original=>{
 const item=new AlbumUploadItem();item.id=require('crypto').randomUUID();item.uri=original.uri;item.name=original.name;item.size=original.size;item.modified=original.modified;return item;
 }))}return items.length},
 validate:async item=>{if(!fs.existsSync(item.uri)||fs.statSync(item.uri).size!==item.size)throw Error('source changed')}}}
class Repo {
 constructor(){this.scope='account-a';this.files=new Map();this.tmp=new Map();this.chunks=0;this.fail=false;this.onChunk=()=>{}}
 cacheScopeHash(){return this.scope}
 async listUploadDestinationPage(dir,type,page){const all=[...this.files].map(([name,bytes])=>({name,size:bytes.length,isDirectory:false}));
 return {entries:all.slice((page-1)*200,page*200),hasMore:page*200<all.length}}
 async prepareUpload(dir,name,id,size){return this.files.has(name)}
 async uploadOffset(dir,id,size){return this.tmp.get(id)?.length||0}
 async uploadChunk(dir,name,id,size,changed,offset,bytes){this.chunks++;const old=this.tmp.get(id)||Buffer.alloc(0), next=Buffer.alloc(offset+bytes.byteLength);
 assert.equal(offset,old.length,'NAS requires the next byte offset');
 old.copy(next,0,0,offset);Buffer.from(bytes).copy(next,offset);this.tmp.set(id,next);this.onChunk();
 if(this.fail){this.fail=false;nasOnline=false;throw new UgreenError(UgreenErrorKind.NAS_UNAVAILABLE,'offline')}
 if(next.length===size){this.files.set(name,next);this.tmp.delete(id)}}
 async removeUploadTemporary(dir,id){this.tmp.delete(id)}
}
async function waitFor(fn){const start=Date.now();while(!fn()){if(Date.now()-start>10000)throw Error('timeout');await new Promise(r=>setTimeout(r,5))}}
async function newManager(repo,items){const m=new AlbumUploadManager();await m.initialize(context,repo,{isUnmetered:()=>true,onChange:()=>{}},()=>{},()=>{},source(items));
 foreground=true;protectedTransfer=false;
 m.setForeground(true);await m.setReady(true);return m}
async function create(m,repo,items){const album=new LocalImageAlbum();album.uri='local-album';album.name='Synthetic album';album.localCount=items.length;
 await m.create(album,'/test',4,repo.scope,false);return m.snapshot()[0]}
async function finish(m,job){await waitFor(()=>['completed','failed'].includes(job.state));await m.setReady(false)}
(async()=>{
 const clientExports={};const clientCode=ts.transpileModule(fs.readFileSync(path.join(root,'entry/src/main/ets/ugreen/UgreenRemoteClient.ets'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 vm.runInThisContext('(function(require,exports){'+clientCode+'\n})')(name=>name==='@kit.NetworkKit'?{http:{RequestMethod:{GET:'GET'}}}:{},clientExports);
 const client=Object.create(clientExports.UgreenRemoteClient.prototype);
 client.requireEndpoints=()=>({baseUrl:'https://nas'});client.authHeaders=async()=>({});client.successData=body=>body.data;
 client.transport={requestJson:async()=>({body:{data:{result:524288}}})};
 assert.equal(await client.uploadOffset('/test','uuid',2000000),524288);
 report('production NAS offset uses acknowledged byte count without replay');
 const a=image('同名.jpg',3,1), b=image('同名.jpg',4,2);assert(AlbumUploadPolicy.validName(a.name));assert(!AlbumUploadPolicy.validName('../bad'));
 assert.equal(AlbumUploadPolicy.alternateName(a,0),AlbumUploadPolicy.alternateName(a,0));assert.notEqual(AlbumUploadPolicy.alternateName(a,0),AlbumUploadPolicy.alternateName(b,0));
 report('deterministic conflict names and invalid path rejection');
 const repo=new Repo();repo.files.set(a.name,Buffer.alloc(3,1));const m=await newManager(repo,[a,b]);const job=await create(m,repo,[a,b]);await finish(m,job);
 assert.equal(job.skipped,1);assert.equal(job.uploaded,1);assert.equal(repo.files.size,2);assert.deepEqual(repo.files.get(AlbumUploadPolicy.alternateName(b,0)),fs.readFileSync(b.uri));
 report('same name/size skips; different size keeps both; exact uploaded bytes');
 await m.setReady(true);const repeat=[image('unused',1,0)];const second=await create(m,repo,[a,b]);await finish(m,second);
 assert.equal(second.skipped,2);assert.equal(second.uploaded,0);assert.equal(repo.files.size,2);report('durable ledger prevents repeated collision copies');
 const big=image('pause.jpg',2*1024*1024+11,7);const r2=new Repo();const m2=await newManager(r2,[big]);r2.onChunk=()=>{foreground=false;m2.setForeground(false)};
 const j2=await create(m2,r2,[big]);await waitFor(()=>j2.state==='waiting_foreground');assert(r2.tmp.size===1);assert.equal(j2.uploaded,0);
 r2.onChunk=()=>{};foreground=true;m2.setForeground(true);await finish(m2,j2);assert.deepEqual(r2.files.get('pause.jpg'),fs.readFileSync(big.uri));
 report('foreground pause and acknowledged offset resume preserves all bytes');
 const bg=image('protected.jpg',1200000,8),rb=new Repo(),mb=await newManager(rb,[bg]);protectedTransfer=true;
 rb.onChunk=()=>{foreground=false;mb.setForeground(false)};
 const jb=await create(mb,rb,[bg]);await finish(mb,jb);assert.equal(jb.completedBytes,bg.size);assert.equal(jb.currentBytes,0);
 assert.deepEqual(rb.files.get(bg.name),fs.readFileSync(bg.uri));foreground=true;protectedTransfer=false;
 report('protected background completes byte-exact upload and counts completed bytes once');
 const off=image('offline.jpg',1200000,9);const r3=new Repo();r3.fail=true;const m3=await newManager(r3,[off]);const j3=await create(m3,r3,[off]);
 await waitFor(()=>j3.state==='waiting_server');assert.equal(j3.failed,0);nasOnline=true;nasListeners.forEach(f=>f());await finish(m3,j3);
 assert.deepEqual(r3.files.get('offline.jpg'),fs.readFileSync(off.uri));report('NAS loss and lost acknowledgment resume without duplicate data');
 const bad=image('changed.jpg',50,4),good=image('good.jpg',55,5);fs.appendFileSync(bad.uri,'changed');const r4=new Repo();const m4=await newManager(r4,[bad,good]);
 const j4=await create(m4,r4,[bad,good]);await finish(m4,j4);assert.equal(j4.failed,1);assert.equal(j4.uploaded,1);
 fs.writeFileSync(bad.uri,Buffer.alloc(50,4));await m4.setReady(true);await m4.toggle(j4.id);await finish(m4,j4);assert.equal(j4.failed,0);assert.equal(j4.uploaded,2);
 report('changed original fails individually; retry only retries failed items');
 const stopped=image('logout.jpg',1200000,6),r5=new Repo();const m5=await newManager(r5,[stopped]);let stopping;
 r5.onChunk=()=>{r5.onChunk=()=>{};stopping=m5.setReady(false)};
 const j5=await create(m5,r5,[stopped]);await waitFor(()=>stopping!==undefined);await stopping;assert.equal(j5.state,'paused');
 r5.scope='account-b';assert.equal(m5.snapshot().length,0);await m5.setReady(true);assert.equal(r5.files.size,0);
 r5.scope='account-a';await m5.setReady(true);assert.equal(j5.state,'paused');await m5.toggle(j5.id);await finish(m5,j5);
 assert.deepEqual(r5.files.get('logout.jpg'),fs.readFileSync(stopped.uri));report('logout pauses durably and other accounts cannot run the batch');
 const s=new AlbumUploadStore();await s.initialize(context);const rows=Array.from({length:1201},(_,i)=>image('large-'+i+'.jpg',1,1));
 await s.append('pagination-test',rows);assert.equal((await s.items('pagination-test',1100)).length,100);assert.equal((await s.items('pagination-test',1200)).length,1);
 await s.remove('pagination-test');report('1201 item SQLite manifest and bounded pagination');
 assert.equal(fs.readdirSync(path.join(testRoot,'ugreen-album-uploads')).length,0);report('staging reclaimed after complete, pause and failure');
 fs.writeFileSync(path.join(root,'temp/album-upload/feature-tests.json'),JSON.stringify({passed:scenarios.length,scenarios},null,2));
 fs.readdirSync(testRoot).filter(n=>fs.statSync(path.join(testRoot,n)).isFile()).forEach(n=>fs.unlinkSync(path.join(testRoot,n)));
})().catch(e=>{console.error(e);process.exitCode=1});

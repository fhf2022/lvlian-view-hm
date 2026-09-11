// Executes the production ArkTS queue and storage budget with in-memory IO/NAS faults.
// node tests/upload-regression.cjs <typescript.js>
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const files = new Map(), prefsData = new Map(), handles = new Map();
let nextFd = 1, nextId = 1, failWrite = false;
const pathOf = p => typeof p === 'number' ? handles.get(p) : p;
const io = {
  OpenMode: { READ_ONLY: 0, CREATE: 1, READ_WRITE: 2 },
  accessSync: p => files.has(p) || p === '/files/ugreen-upload-tasks', mkdirSync() {},
  statSync(p) { const b = files.get(pathOf(p)); if (!b) throw Error('missing'); return {size:b.length,mtime:1,isFile:()=>true}; },
  async stat(p) { return this.statSync(p); },
  listFileSync(p) { return [...files.keys()].filter(k => k.startsWith(p + '/')).map(k => k.slice(p.length + 1)); },
  openSync(p, mode) { if (mode & 1) files.set(p,Buffer.alloc(0)); if (!files.has(p)) throw Error('missing'); const fd=nextFd++;handles.set(fd,p);return {fd}; },
  async open(p,mode) { return this.openSync(p,mode); }, closeSync(f) {handles.delete(typeof f === 'number' ? f : f.fd);},
  async read(fd, buffer, {offset}) { const part=files.get(pathOf(fd)).subarray(offset,offset+buffer.byteLength);new Uint8Array(buffer).set(part);return part.length; },
  writeSync(fd,buffer,{offset,length}) { if(failWrite) throw Error('disk full');const p=pathOf(fd),old=files.get(p),out=Buffer.alloc(Math.max(old.length,offset+length));old.copy(out);Buffer.from(buffer).copy(out,offset,0,length);files.set(p,out);return length; },
  unlinkSync(p) {if(!files.delete(p))throw Error('missing');},utimes(){}
};
const prefs={async get(k,d){return prefsData.has(k)?prefsData.get(k):d},async put(k,v){prefsData.set(k,v)},async flush(){}};
const mocks={
  '@kit.AbilityKit':{}, '@kit.CoreFileKit':{fileIo:io,fileUri:{FileUri:class{constructor(u){this.name=u.split('/').pop()}}}},
  '@kit.ArkData':{preferences:{async getPreferences(){return prefs}}}, '@kit.ArkTS':{util:{generateRandomUUID:()=>`test-${nextId++}`}},
  '../ugreen/UgreenErrors':{UgreenError:class extends Error{constructor(k,m){super(m)}},UgreenErrorKind:{UNKNOWN:0}}
};
function load(relative) {const exports={};const js=ts.transpileModule(fs.readFileSync('entry/src/main/ets/'+relative+'.ets','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;vm.runInNewContext(js,{exports,require:k=>{assert.ok(mocks[k],k);return mocks[k]},console});return exports;}
const {StorageBudget:B}=load('download/StorageBudget');mocks['../download/StorageBudget']={StorageBudget:B};
mocks['../model/FileEntry']=load('model/FileEntry');
const {UploadQueueManager:Queue}=load('upload/UploadQueueManager');
const context={filesDir:'/files',cacheDir:'/cache',tempDir:'/tmp',databaseDir:'/db',preferencesDir:'/prefs'};
let scope='account-a', unmetered=true, skip=false, failChunk=0, failCleanup=false, calls=[], server=Buffer.alloc(0);
const network={isUnmetered:()=>unmetered,onChange(){}};
const repo={cacheScopeHash:()=>scope,async prepareUpload(){return skip},async uploadOffset(){return Math.max(0,server.length-1)},
  async uploadChunk(dir,name,uuid,size,changed,offset,bytes){calls.push(offset);if(failChunk && calls.length===failChunk)throw Error('network interrupted');const out=Buffer.alloc(Math.max(server.length,offset+bytes.byteLength));server.copy(out);Buffer.from(bytes).copy(out,offset);server=out;},
  async removeUploadTemporary(){if(failCleanup)throw Error('offline');server=Buffer.alloc(0)}
};
async function settle(q){for(let n=0;n<100;n++){if(!q.running) return;await q.running;}throw Error('queue did not settle');}
async function reset(){files.clear();prefsData.clear();server=Buffer.alloc(0);calls=[];skip=false;failChunk=0;failWrite=false;failCleanup=false;scope='account-a';unmetered=true;B.initialize(context,4*1024*1024);const q=new Queue();await q.initialize(context,repo,network,()=>{});await q.setReady(true);return q;}
(async()=>{
  let q=await reset();const original=Buffer.alloc(1300000);for(let i=0;i<original.length;i++)original[i]=i%251;files.set('/source/photo.jpg',original);failChunk=2;
  await q.enqueue('/source/photo.jpg','/NAS/photos',scope);await settle(q);let task=q.snapshot()[0];
  assert.equal(task.status,'failed');assert.equal(task.receivedBytes,512*1024);assert.equal(B.usage(),original.length);
  failChunk=0;await q.toggle(task.id);await settle(q);assert.equal(task.status,'completed');assert.ok(calls.includes(512*1024-1));assert.deepEqual(server,original);assert.ok(!files.has(task.stagingPath));assert.ok(files.has('/source/photo.jpg'));
  console.log('PASS: chunk failure, replay-byte resume, original bytes unchanged, completed staging cleanup');
  q=await reset();files.set('/source/item.bin',Buffer.alloc(42));skip=true;await q.enqueue('/source/item.bin','/NAS',scope);await settle(q);task=q.snapshot()[0];assert.equal(task.skipped,true);assert.equal(calls.length,0);assert.ok(!files.has(task.stagingPath));
  q=await reset();files.set('/source/item.bin',Buffer.alloc(42));failWrite=true;await q.enqueue('/source/item.bin','/NAS',scope);await settle(q);task=q.snapshot()[0];assert.equal(task.status,'failed');assert.ok(!files.has(task.stagingPath));assert.equal(handles.size,0);
  q=await reset();B.setLimit(20);files.set('/source/item.bin',Buffer.alloc(42));await q.enqueue('/source/item.bin','/NAS',scope);await settle(q);task=q.snapshot()[0];assert.equal(task.status,'failed');assert.equal(B.usage(),0);assert.equal(calls.length,0);
  console.log('PASS: same-name skip, failed-copy rollback, quota enforcement, source isolation');
  q=await reset();unmetered=false;files.set('/source/item.bin',Buffer.alloc(42));await q.enqueue('/source/item.bin','/NAS',scope);await settle(q);task=q.snapshot()[0];assert.equal(task.status,'waiting_wifi');scope='account-b';assert.equal(q.snapshot().length,0);await assert.rejects(q.enqueue('/source/item.bin','/NAS','account-a'));scope='account-a';
  const restored=new Queue();await restored.initialize(context,repo,network,()=>{});await restored.setReady(true);assert.equal(restored.snapshot().length,1);task=restored.snapshot()[0];await restored.toggle(task.id);await settle(restored);assert.equal(task.status,'completed');
  q=await reset();files.set('/source/item.bin',Buffer.alloc(42));failChunk=1;await q.enqueue('/source/item.bin','/NAS',scope);await settle(q);task=q.snapshot()[0];failCleanup=true;await assert.rejects(q.remove(task.id));assert.equal(q.snapshot().length,1);assert.ok(files.has(task.stagingPath));failCleanup=false;await q.remove(task.id);assert.equal(q.snapshot().length,0);assert.ok(!files.has(task.stagingPath));
  console.log('PASS: metered gating, account isolation, restart recovery, remote-cleanup failure retains retry');
})().catch(e=>{console.error(e);process.exitCode=1});

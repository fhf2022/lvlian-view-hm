// Run: node tests/folder-share-regression.cjs <typescript.js>
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), crypto = require('node:crypto');
const ts = require(process.argv[2]);
const root = fs.mkdtempSync(path.resolve('temp/folder-share-suite-'));
const real = p => {
  const result = path.resolve(root, p.replace(/^\/+/, ''));
  assert.ok(result.startsWith(root + path.sep)); return result;
};
const open = new Set(), pins = new Map(), shared = new Map();
let now = Date.now(), failCopy = false, limit = Infinity, active = 0, maxActive = 0, downloads = 0;
const clock = class extends Date { static now() { return now; } };
const io = {
  accessSync: p => fs.existsSync(real(p)),
  mkdir: p => fs.promises.mkdir(real(p), { recursive: true }),
  listFile: p => fs.promises.readdir(real(p)), readText: p => fs.promises.readFile(real(p), 'utf8'),
  stat: p => fs.promises.stat(real(p)),
  openSync(p) { const fd=fs.openSync(real(p),'w+');open.add(fd);return {fd}; },
  async open(p) { return io.openSync(p); },
  closeSync(file) { const fd=typeof file==='number'?file:file.fd;fs.closeSync(fd);open.delete(fd); },
  truncateSync: fs.ftruncateSync,
  async write(fd, bytes) {
    return await new Promise((resolve,reject)=>fs.write(fd,Buffer.from(bytes),0,bytes.byteLength,null,
      (error,count)=>error?reject(error):resolve(count)));
  },
  async copyFile(src,dest) {
    if (failCopy) throw new Error('public copy failed');
    assert.equal(typeof dest,'number','public copy reuses the writable fd; it must not replace the reserved path');
    const bytes=await fs.promises.readFile(real(src));
    await new Promise((resolve,reject)=>fs.write(dest,bytes,0,bytes.length,0,error=>error?reject(error):resolve()));
  },
  rename: (a,b)=>fs.promises.rename(real(a),real(b)), unlink: p=>fs.promises.unlink(real(p)),
  rmdir: p=>fs.promises.rmdir(real(p)), OpenMode: {CREATE:1,READ_WRITE:2,TRUNC:4,EXCL:8}
};
const B = {
  pin(p) { pins.set(p,(pins.get(p)||0)+1); },
  unpin(p) { pins.set(p,(pins.get(p)||0)-1); },
  registerSharedTemporary(p,size,deadline=0) { shared.set(p,{size,deadline}); },
  forgetSharedTemporary(p) { shared.delete(p); },
  admit(p,size) { if ([...shared].reduce((n,[key,item])=>n+(key===p?size:item.size),0)>limit) throw new Error('quota full'); },
  sync(p) { if(shared.has(p)&&fs.existsSync(real(p)))shared.get(p).size=fs.statSync(real(p)).size; }
};
const baseUri='file://docs/storage/Users/currentUser/Download/cn.fhf.linkfiles';
const mocks={
  '@kit.AbilityKit':{}, '@kit.CoreFileKit':{fileIo:io,fileUri:{FileUri:class{constructor(uri){this.path=decodeURIComponent(uri.replace('file://docs',''));}}}},
  '@kit.ArkTS':{util:{generateRandomUUID:()=>crypto.randomUUID(),TextEncoder:class extends TextEncoder{encodeInto(text){return this.encode(text)}}}},
  '../model/FileEntry':{}, '../download/StorageBudget':{StorageBudget:B},
  '../download/DownloadDestination':{DownloadDestination:{directoryUri:async()=>baseUri}}
};
const ex={};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/share/FolderSharePreparer.ets','utf8'),
  {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
  {exports:ex,require:k=>{assert.ok(mocks[k],k);return mocks[k]},console,Date:clock,Map,Set});
const index=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
const a=index.indexOf('  private async cacheGestureEntries('), b=index.indexOf('\n  private async prepareGestureShare',a);
const cacheEx={};
vm.runInNewContext(ts.transpileModule('export class Cache {\n'+index.slice(a,b)+'\n}',
  {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
  {exports:cacheEx,StorageBudget:B,CacheManager:{exists:p=>!!p&&fs.existsSync(real(p))},console});
const worker=new cacheEx.Cache();
worker.ensureCachedFile=async(e,_progress,valid)=>{
  assert.ok(valid()); maxActive=Math.max(maxActive,++active); downloads++;
  const p='/cache/'+crypto.createHash('sha256').update(e.path+e.modifiedTime).digest('hex');
  await fs.promises.mkdir(real('/cache'),{recursive:true});
  await fs.promises.writeFile(real(p),e.path);
  active--; return p;
};
const item=(p,dir=false)=>({path:p,name:p.slice(p.lastIndexOf('/')+1),isDirectory:dir,rootType:3,
  modifiedTime:1,size:dir?0:Buffer.byteLength(p),etag:'',checksum:''});
const folder=item('/nas/目录 %测试',true), sub=item(folder.path+'/子目录',true), empty=item(folder.path+'/空目录',true);
const first=item(folder.path+'/same.txt'), second=item(sub.path+'/same.txt'), chinese=item(sub.path+'/中文.txt');
let valid=true, listings=0;
const source=()=>({valid:()=>valid,
  async list(e,page) {
    listings++;
    if(e.path===folder.path)return page===1?{entries:[first,sub],hasMore:true}:{entries:[empty],hasMore:false};
    return {entries:e.path===sub.path?[second,chinese]:[],hasMore:false};
  },
  async cache(entries,owned,current,materialize) {
    const result=await worker.cacheGestureEntries(entries,owned,current,materialize);
    if(result.failedCount)throw new Error(result.failureMessage||'file preparation failed');
    return result.localPaths;
  }
});
const release=owned=>{for(const p of owned)B.unpin(p)};
const context={filesDir:'/private'};
(async()=>{
  const service=new ex.FolderSharePreparer();await service.initialize(context);
  let owned=[];const result=await service.prepare(folder,'account-a',source(),owned);release(owned);
  assert.ok(result.uri.startsWith(baseUri+'/temp/.linkfiles-folder-share-v1/'));
  assert.ok(result.uri.endsWith('/'+encodeURIComponent(folder.name)),'URI encodes each source folder name');
  assert.equal(fs.readFileSync(real(result.path+'/same.txt'),'utf8'),first.path);
  assert.equal(fs.readFileSync(real(result.path+'/子目录/same.txt'),'utf8'),second.path);
  assert.equal(fs.readFileSync(real(result.path+'/子目录/中文.txt'),'utf8'),chinese.path);
  assert.ok(fs.statSync(real(result.path+'/空目录')).isDirectory(),'materializer retains source layout even if system transmission omits empties');
  assert.equal(maxActive,2,'reuse the production two-worker cache path');
  assert.equal(open.size,0,'all output and journal descriptors close');
  assert.ok([...pins.values()].every(n=>n===0));
  assert.ok([...shared.values()].every(x=>x.deadline>now),'handover is not interpreted as delivery completion');
  const oldDownloads=downloads;owned=[];
  assert.equal((await service.prepare(folder,'account-a',source(),owned)).path,result.path);
  assert.equal(downloads,oldDownloads,'fresh metadata + intact matching snapshot reuse copies');release(owned);
  first.modifiedTime++;owned=[];
  assert.notEqual((await service.prepare(folder,'account-a',source(),owned)).path,result.path,'child version invalidates snapshot');release(owned);
  owned=[];assert.notEqual((await service.prepare(folder,'account-b',source(),owned)).path,result.path,'accounts cannot share snapshot identity');release(owned);
  const loose=item('/nas/loose.txt');owned=[];
  const mixed=await service.prepareSelection([folder,loose],'mixed',source(),owned);release(owned);
  assert.ok(mixed[loose.path].uri.startsWith(baseUri));
  assert.equal(path.dirname(mixed[folder.path].path),path.dirname(mixed[loose.path].path),'mixed records share one public staging job');
  assert.equal(fs.readFileSync(real(mixed[loose.path].path),'utf8'),loose.path);
  await assert.rejects(service.prepareSelection([loose,item('/different/LOOSE.txt')],'case-clash',source(),[]),/同名/);
  let bad=source();bad.list=async()=>({entries:[item(folder.path+'/../outside')],hasMore:false});
  await assert.rejects(service.prepare(folder,'unsafe',bad,[]),/路径异常/);
  bad=source();bad.list=async()=>({entries:[],hasMore:true});
  await assert.rejects(service.prepare(folder,'broken-page',bad,[]),/不完整/);
  bad=source();bad.list=async()=>({entries:[],hasMore:false});
  await assert.rejects(service.prepare(folder,'empty',bad,[]),/没有可分享/);
  valid=false;await assert.rejects(service.prepare(folder,'cancel',source(),[]),/已变化/);valid=true;
  failCopy=true;owned=[];const before=downloads;
  await assert.rejects(service.prepare(folder,'copy-failure',source(),owned),/public copy failed/);release(owned);failCopy=false;
  assert.ok(downloads-before<=2,'a folder failure stops the remaining downloads');
  assert.equal(open.size,0);assert.ok([...pins.values()].every(n=>n===0));
  limit=0;owned=[];await assert.rejects(service.prepare(folder,'quota',source(),owned),/quota full/);release(owned);limit=Infinity;
  assert.equal(open.size,0);assert.ok([...pins.values()].every(n=>n===0));
  const ordinary='/storage/Users/currentUser/Download/cn.fhf.linkfiles/ordinary-user.txt';
  await fs.promises.mkdir(path.dirname(real(ordinary)),{recursive:true});await fs.promises.writeFile(real(ordinary),'keep');
  const restarted=new ex.FolderSharePreparer();await restarted.initialize(context);
  await restarted.sweep();assert.ok(fs.existsSync(real(result.path+'/same.txt')),'active leases survive restart');
  now+=24*60*60*1000+1;await restarted.sweep();
  assert.ok(!fs.existsSync(real(result.path+'/same.txt')),'expired owned staging files cleaned');
  assert.equal(fs.readFileSync(real(ordinary),'utf8'),'keep','ordinary downloads are outside cleanup scope');
  assert.equal(shared.size,0);assert.equal(open.size,0);
  console.log('PASS folder share: production cache workers, fd copies, tree/Unicode/duplicate names, metadata/account reuse, unsafe pages, cancellation, fail-fast, quota cleanup, journal restart, leases and ordinary-download isolation');
})().finally(()=>fs.rmSync(root,{recursive:true,force:true})).catch(e=>{console.error(e);process.exitCode=1});

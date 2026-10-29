// Run: node tests/storage-regression.cjs <path-to-typescript.js>
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const files = new Map(); const data = new Map(); let failCopy = false;
let foreground=true;
const put = (p, size, time=1) => files.set(p,{size,mtime:time});
const io = {
 statSync(p) { if(files.has(p)) return {...files.get(p),isFile:()=>true,isDirectory:()=>false};
 if([...files.keys()].some(k=>k.startsWith(p+'/'))) return {isFile:()=>false,isDirectory:()=>true}; throw Error('missing'); },
 listFileSync(p) { return [...new Set([...files.keys()].filter(k=>k.startsWith(p+'/')).map(k=>k.slice(p.length+1).split('/')[0]))]; },
 unlinkSync(p) { if(!files.delete(p)) throw Error('missing'); },
 utimes(p,t) { if(files.has(p)) files.get(p).mtime=t/1000; }, mkdirSync(){},
 async copyFile(a,b) {put(b, failCopy ? 1 : files.get(a).size); if(failCopy) throw Error('copy failed');}
};
const prefs={async get(k,d){return data.has(k)?data.get(k):d},async put(k,v){data.set(k,v)},async delete(k){data.delete(k)},async flush(){},async getAll(){return Object.fromEntries(data)}};
const mocks={'@kit.AbilityKit':{},'@kit.CoreFileKit':{fileIo:io,fileUri:{FileUri:class{constructor(uri){this.path=uri}}},picker:{DocumentSaveOptions:class{},DocumentPickerMode:{DOWNLOAD:1},DocumentViewPicker:class{async save(o){assert.equal(o.pickerMode,1);return ['/Download/com.example.ugreenlink']}}}},'@kit.ArkData':{preferences:{async getPreferences(){return prefs}}},'../ugreen/UgreenErrors':{UgreenError:class extends Error{constructor(k,m){super(m)}},UgreenErrorKind:{UNKNOWN:0}}};
function load(name) {const exports={};const source=fs.readFileSync('entry/src/main/ets/download/'+name+'.ets','utf8');const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;vm.runInNewContext(js,{exports,require:k=>{assert.ok(mocks[k],k);return mocks[k]},console});return exports;}
mocks['../transfer/TransferBackgroundManager']={TransferBackgroundManager:{shared:()=>({isForeground:()=>foreground})}};
const {StorageBudget:B}=load('StorageBudget');mocks['./StorageBudget']={StorageBudget:B};
const context={cacheDir:'/cache',tempDir:'/temp',filesDir:'/files',databaseDir:'/db',preferencesDir:'/prefs'};
(async()=>{
 put('/cache/old',30);put('/temp/nested/new',20,2);put('/files/ugreen-video-transfers/resume.part',30,3);put('/Download/com.example.ugreenlink/user',1000);put('/files/ugreen-thumbnail-cache/thumb',40);
 B.initialize(context,100);assert.equal(B.usage(),80);assert.equal(B.persistentUsage(),40);
 B.pin('/cache/old');const evicted=[];B.onEvicted(p=>evicted.push(p));B.admit('/cache/incoming',40);assert.ok(files.has('/cache/old'));assert.ok(!files.has('/temp/nested/new'));assert.equal(evicted.length,1);
 B.clearDisposable();assert.ok(files.has('/files/ugreen-video-transfers/resume.part'));assert.ok(files.has('/Download/com.example.ugreenlink/user'));
 B.removeWhenUnused('/cache/old');assert.ok(files.has('/cache/old'));B.unpin('/cache/old');assert.ok(!files.has('/cache/old'));
 B.pin('/files/ugreen-video-transfers/resume.part');assert.throws(()=>B.setLimit(10));B.unpin('/files/ugreen-video-transfers/resume.part');B.admit('/cache/large',80);assert.ok(!files.has('/files/ugreen-video-transfers/resume.part'));
 const {DownloadDestination:D}=load('DownloadDestination');D.initialize(context);put('/cache/source.part',12);failCopy=true;await assert.rejects(D.save('/cache/source.part','test.jpg'));assert.ok(files.has('/cache/source.part'));assert.ok(!files.has('/Download/com.example.ugreenlink/test.jpg'));
 failCopy=false;const dest=await D.save('/cache/source.part','test.jpg');assert.equal(dest,'/Download/com.example.ugreenlink/test.jpg');assert.equal(await D.save('/cache/source.part','test.jpg'),dest);
 B.pin('/cache/source.part');await D.acknowledge('/cache/source.part');assert.ok(files.has('/cache/source.part'));B.unpin('/cache/source.part');assert.ok(!files.has('/cache/source.part'));assert.ok(files.has(dest));
 put('/cache/next.part',5);assert.match(await D.save('/cache/next.part','test.jpg'),/test \(1\)\.jpg$/);assert.throws(()=>D.safeRelativePath('../escape'));
 B.clearDisposable();assert.ok(files.has(dest));
 put('/cache/interrupted.part',9);put('/Download/com.example.ugreenlink/interrupted.jpg',2);
 data.set('/cache/interrupted.part',JSON.stringify({source:'/cache/interrupted.part',target:'/Download/com.example.ugreenlink/interrupted.jpg',size:9,committed:false}));
 const {DownloadDestination:Restarted}=load('DownloadDestination');Restarted.initialize(context);
 const recovered=await Restarted.save('/cache/interrupted.part','interrupted.jpg');
 assert.equal(files.get(recovered).size,9);assert.ok(!files.has('/Download/com.example.ugreenlink/interrupted (1).jpg'));
 assert.ok(files.has(dest));
 foreground=false;
 assert.equal(await D.directory(),'/Download/com.example.ugreenlink');
 const {DownloadDestination:Ungrant}=load('DownloadDestination');Ungrant.initialize(context);
 await assert.rejects(Ungrant.directory(),/前台授权/);foreground=true;
 assert.equal(await Ungrant.directory(),'/Download/com.example.ugreenlink');
 files.clear();
 const part='/cache/image.part', meta=part+'.resume.json';
 put(part,60,1);put(meta,5,2);put('/cache/disposable',20,3);put('/cache/orphan.part.resume.json',5,4);
 B.initialize(context,100);assert.equal(B.usage(),90,'partial metadata counts toward the same budget');
 B.clearDisposable();assert.ok(files.has(part)&&files.has(meta),'manual clear preserves resumable pairs');
 assert.ok(!files.has('/cache/disposable')&&!files.has('/cache/orphan.part.resume.json'),'ordinary and orphan files cleared');
 B.scan();assert.equal(B.usage(),65);
 B.pin(part);B.admit('/cache/new',35);assert.ok(files.has(meta),'pinning bytes also protects resume record');
 B.unpin(part);B.pin(meta);assert.throws(()=>B.admit('/cache/new',36),'pinning metadata also protects bytes');B.unpin(meta);
 B.admit('/cache/new',36);assert.ok(!files.has(part)&&!files.has(meta),'pressure evicts whole pair');assert.equal(B.usage(),0);
 put(part,60,2);put(meta,5,1);B.scan();B.admit('/cache/new',40);
 assert.ok(!files.has(part)&&!files.has(meta),'metadata-first LRU order must not double count reclaimed bytes');assert.equal(B.usage(),0);
 put(part,60,1);put(meta,5,2);B.scan();B.protect(()=>[part]);
 assert.throws(()=>B.admit('/cache/new',36));assert.ok(files.has(meta),'protected partial protects metadata');B.protect(()=>[]);
 const unlink=io.unlinkSync;io.unlinkSync=p=>{if(p===meta)throw Error('busy metadata');return unlink(p)};
 assert.throws(()=>B.admit('/cache/new',96));assert.equal(B.usage(),5,'failed companion removal must still count its bytes');
 io.unlinkSync=unlink;B.clearDisposable();assert.equal(B.usage(),0,'orphan left by failed unlink is cleaned later');
 // Production supplies empty audio/video paths when nothing is playing.
 // An absent resume companion is also empty; neither may protect every image.
 files.clear();put('/cache/old.jpg',90,1);put('/cache/playing.mp4',10,2);
 B.initialize(context,100);B.protect(()=>['','','/cache/playing.mp4']);B.pin('');
 B.admit('/cache/next.jpg',40);assert.ok(!files.has('/cache/old.jpg'),'quota pressure evicts ordinary originals with empty player paths');assert.ok(files.has('/cache/playing.mp4'),'real player source stays protected');
 B.unpin('');put('/cache/old.jpg',90,1);B.scan();B.setLimit(10);assert.ok(!files.has('/cache/old.jpg'),'empty admission path cannot protect all files when lowering quota');
 put('/cache/old.jpg',20,1);put(part,8,2);put(meta,2,3);B.scan();B.pin('');B.clearDisposable();
 assert.ok(!files.has('/cache/old.jpg'),'manual clear ignores empty companion and empty protection entries');assert.ok(files.has(part)&&files.has(meta),'manual clear still retains resume pair');assert.ok(files.has('/cache/playing.mp4'));
 B.unpin('');B.protect(()=>[]);
 console.log('PASS: paired partial metadata, manual clear, orphan cleanup, quota accounting and pin protection');
 console.log('PASS: cached public directory grant works in background; a fresh process cannot invoke background picker');
 console.log('PASS: restart recovers interrupted public copy');console.log('PASS: shared quota, LRU, partial eviction, pins, limit rollback, public isolation, copy rollback/retry, deferred cleanup, collision and traversal');
})().catch(e=>{console.error(e);process.exitCode=1});

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
 console.log('PASS: cached public directory grant works in background; a fresh process cannot invoke background picker');
 console.log('PASS: restart recovers interrupted public copy');console.log('PASS: shared quota, LRU, partial eviction, pins, limit rollback, public isolation, copy rollback/retry, deferred cleanup, collision and traversal');
})().catch(e=>{console.error(e);process.exitCode=1});

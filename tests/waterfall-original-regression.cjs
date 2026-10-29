const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const ts = require(process.argv[2]), cache = new Map();
function load(name) {
 if(cache.has(name))return cache.get(name);
 const exports={};cache.set(name,exports);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/'+name+'.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}}).outputText,{exports,console,Observed:c=>c,require:key=>load(path.posix.normalize(path.posix.join(path.posix.dirname(name),key)))});
 return exports;
}
const {WaterfallOriginalLoader}=load('media/WaterfallOriginalLoader');
const {FileEntry}=load('model/FileEntry');
const tick=async()=>{for(let i=0;i<30;i++)await Promise.resolve();};
function harness(){
 const h={scope:'A',jobs:[],ready:[],running:0,max:0};
 h.entries=Array.from({length:1000},(_,i)=>Object.assign(new FileEntry(),{name:i+'.jpg',path:'/photos/'+i,size:1000,modifiedTime:1}));
 h.key=e=>h.scope+e.path+':'+e.modifiedTime;
 h.loader=new WaterfallOriginalLoader({fileKey:h.key,
 download(entry,valid,signal){let resolve,reject;const p=new Promise((a,b)=>{resolve=a;reject=b});h.max=Math.max(h.max,++h.running);const job={entry,valid,signal,finish:()=>resolve('/cache/'+entry.name),fail:()=>reject(Error('network')),abort:()=>reject(Error('cancel'))};h.jobs.push(job);return p.finally(()=>h.running--);},
 async ready(entry,local,valid){assert.ok(valid());h.ready.push(entry.path);}, finished(){}
 });return h;
}
(async()=>{
 const h=harness();h.loader.update(h.entries.slice(0,12));
 assert.deepEqual(h.jobs.map(j=>j.entry.path),['/photos/0','/photos/1']);
 const viewer=h.loader.requestMember(h.entries[10]);
 assert.ok(viewer);assert.equal(h.jobs.length,2,'Viewer borrowing preserves active group work');
 h.jobs[0].finish();await tick();assert.equal(h.jobs[2].entry.path,'/photos/10','queued Viewer member promoted');
 h.jobs[2].finish();assert.equal(await viewer,'/cache/10.jpg');await tick();
 assert.equal(h.ready.filter(p=>p==='/photos/10').length,1,'single physical original writer');
 const before=h.jobs.length;h.loader.update(h.entries.slice(60,72));
 assert.equal(h.jobs.length,before);assert.ok(h.jobs[1].signal.isCancelled());
 h.jobs[1].abort();h.jobs.at(-1).abort();await tick();assert.equal(h.jobs.length,before+2,'new jobs wait for physical cleanup');
 h.loader.reset();h.scope='B';h.loader.update(h.entries.slice(60,72));
 const reset=h.jobs.length;h.jobs.at(-1).abort();h.jobs.at(-2).abort();await tick();assert.equal(h.jobs.length,reset+2);assert.equal(h.max,2);
 const k=harness();k.loader.update(k.entries.slice(0,12),1);assert.equal(k.jobs.length,1);
 k.jobs[0].fail();await tick();assert.equal(k.jobs[1].entry.path,'/photos/1');
 const retry=k.loader.requestMember(k.entries[0]);k.jobs[1].finish();await tick();assert.equal(k.jobs[2].entry.path,'/photos/0');k.jobs[2].finish();await retry;
 const q=harness();q.loader.update(q.entries.slice(0,12));
 for(let i=0;i<12;i++){assert.ok(q.jobs[i]);q.jobs[i].finish();await tick();}
 assert.equal(q.jobs.length,12,'explicit one-group targets, not full directory');assert.equal(q.max,2);
 const {DownloadCancellation}=load('core/network/DownloadCancellation');const prep=harness();prep.loader.update(prep.entries.slice(0,12));
 const signal=new DownloadCancellation();let end,started=false;
 const geometry=prep.loader.runPreparation(async()=>{started=true;prep.running++;prep.max=Math.max(prep.max,prep.running);try{await new Promise(r=>end=r);return '/geometry'}finally{prep.running--}},signal);
 assert.equal(started,false,'fallback geometry cannot bypass two physical slots');prep.jobs[0].finish();await tick();assert.equal(started,true);
 signal.cancel();await assert.rejects(geometry);assert.equal(prep.loader.active,2,'cancellation cannot release an occupied IO slot early');
 prep.jobs[1].finish();await tick();assert.equal(prep.max,2);end();await tick();assert.equal(prep.max,2);
 const index=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
 assert.doesNotMatch(index,/waterfallOriginalLoader\?\.pause/,'scrolling and Viewer never interrupt group originals');
 console.log('PASS explicit group targets, 2 physical slots, queued Viewer promotion/shared promise, reset/account isolation, retry and no directory-wide loading');
})().catch(e=>{console.error(e);process.exitCode=1});

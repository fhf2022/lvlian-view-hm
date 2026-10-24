const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const ts = require(process.argv[2]), cache = new Map();
function load(name) {
 if(cache.has(name))return cache.get(name);
 const exports={};cache.set(name,exports);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/'+name+'.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}}).outputText,{exports,console,Observed:c=>c,require:key=>load(path.posix.normalize(path.posix.join(path.posix.dirname(name),key)))});
 return exports;
}
const {WaterfallOriginalLoader,waterfallLoadRange}=load('media/WaterfallOriginalLoader');
const {FileEntry}=load('model/FileEntry');
const tick=async()=>{for(let i=0;i<30;i++)await Promise.resolve();};
function harness(){
 const h={scope:'A',jobs:[],ready:[],running:0,max:0};
 h.entries=Array.from({length:1000},(_,i)=>Object.assign(new FileEntry(),{name:i+'.jpg',path:'/photos/'+i,size:1000,modifiedTime:1}));
 h.key=e=>h.scope+e.path+':'+e.modifiedTime;
 h.loader=new WaterfallOriginalLoader({fileKey:h.key,
 download(entry,valid,signal){let resolve,reject;const p=new Promise((a,b)=>{resolve=a;reject=b});h.max=Math.max(h.max,++h.running);const job={entry,valid,signal,finish:()=>resolve('/cache/'+entry.name),fail:()=>reject(Error('network')),abort:()=>reject(Error('cancel'))};h.jobs.push(job);return p.finally(()=>h.running--);},
 async ready(entry,local,valid){assert.ok(valid());h.ready.push(entry.path);}
 });return h;
}
(async()=>{
 for(let first=0;first<1000;first+=7)for(let width=0;width<130;width+=5){const last=Math.min(999,first+width),r=waterfallLoadRange(first,last,1000);assert.ok(r.start<=first&&r.end>=last);assert.ok(r.end-r.start+1<=r.groupSize*3);}
 assert.equal(waterfallLoadRange(100,108,1000).groupSize,12);
 assert.equal(waterfallLoadRange(0,0,0).end,-1);
 const h=harness();h.loader.update(h.entries,100,108,false);assert.deepEqual(h.jobs.map(j=>j.entry.path),['/photos/100','/photos/101']);
 h.loader.update(h.entries,500,510,true);assert.ok(h.jobs.every(j=>j.signal.isCancelled()));assert.equal(h.jobs.length,2);
 h.loader.update(h.entries,500,510,false);assert.equal(h.jobs.length,2,'cancelling transfers still occupy both slots');
 h.jobs[0].abort();h.jobs[1].abort();await tick();assert.deepEqual(h.jobs.slice(2).map(j=>j.entry.path),['/photos/500','/photos/501']);
 h.jobs[2].finish();await tick();assert.deepEqual(h.ready,['/photos/500']);assert.equal(h.jobs[4].entry.path,'/photos/502');assert.equal(h.max,2);
 const before=h.jobs.length;h.loader.pause();h.jobs[3].finish();h.jobs[4].finish();await tick();assert.equal(h.jobs.length,before,'scrolling cannot launch queued originals');
 h.loader.update(h.entries,500,510,false);await tick();assert.equal(h.jobs.length,before+2);
 h.loader.reset();h.scope='B';h.loader.update(h.entries,500,510,false);assert.equal(h.jobs.length,before+2,'reset does not free physical slots');
 h.jobs.at(-1).abort();h.jobs.at(-2).abort();await tick();assert.equal(h.jobs.length,before+4);assert.equal(h.max,2);
 const k=harness();k.loader.update(k.entries,0,7,false,1);assert.equal(k.jobs.length,1);let settled=false;const settling=k.loader.settle(k.entries[0]).then(()=>settled=true);await tick();assert.equal(settled,false);k.loader.pause();k.jobs[0].finish();await settling;assert.equal(settled,true);
 k.loader.invalidate(k.entries[0]);k.loader.update(k.entries,0,7,false,1);assert.equal(k.jobs[1].entry.path,'/photos/0','evicted disk files are eligible again');k.jobs[1].fail();await tick();assert.equal(k.jobs[2].entry.path,'/photos/1','failed item does not starve visible neighbours');
 const q=harness();q.loader.update(q.entries,0,7,false);for(let i=0;i<36;i++){assert.ok(q.jobs[i]);q.jobs[i].finish();await tick();}assert.equal(q.jobs.length,36,'exactly three groups, not whole directory');assert.equal(q.max,2);
 const empty=harness();empty.loader=new WaterfallOriginalLoader({fileKey:empty.key,async download(){empty.jobs.push(1);return '';},async ready(){throw Error('not ready');}});empty.loader.update(empty.entries,0,5,false);for(let i=0;i<5;i++)await tick();assert.equal(empty.jobs.length,36,'network-policy refusal cannot spin retry');
 const index=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
 const start=index.indexOf('  private completeWaterfallDecode('),end=index.indexOf('  private setSearchScope(',start);assert.doesNotMatch(index.slice(start,end),/waterfallActiveDecodes/,'Image callbacks must never release a decoder slot');
 console.log('PASS waterfall windows, two physical writers, fast-scroll cancellation, account/reset, viewer promotion, eviction, one decoder owner');
})().catch(e=>{console.error(e);process.exitCode=1});

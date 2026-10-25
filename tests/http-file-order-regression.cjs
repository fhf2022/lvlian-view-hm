const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),ts=require(process.argv[2]);
const cache=new Map(),files=new Map(),fds=new Map(),pins=new Map();let serial=0,scenario,reads=0,maxRead=0;
const bytes=s=>Buffer.from(s),put=(p,s)=>files.set(p,bytes(s)),value=p=>files.get(p)?.toString();
const io={OpenMode:{READ_ONLY:1,WRITE_ONLY:2,CREATE:4,APPEND:8,TRUNC:16},
 openSync(p,mode){if(mode&16)files.set(p,Buffer.alloc(0));if(!files.has(p)){if(mode&4)files.set(p,Buffer.alloc(0));else throw Error('missing '+p)}const fd=++serial;fds.set(fd,{path:p,at:mode&8?files.get(p).length:0});return{fd}},
 closeSync(fd){assert.ok(fds.delete(fd),'close valid fd')},statSync:p=>({size:files.get(p).length}),
 writeSync(fd,buffer){const f=fds.get(fd),data=Buffer.from(buffer),old=files.get(f.path);const out=Buffer.alloc(Math.max(old.length,f.at+data.length));old.copy(out);data.copy(out,f.at);f.at+=data.length;files.set(f.path,out);return data.length},
 async write(fd,b){return io.writeSync(fd,b)},async read(fd,buffer){reads++;maxRead=Math.max(maxRead,buffer.byteLength);const f=fds.get(fd),data=files.get(f.path),n=Math.min(buffer.byteLength,data.length-f.at);new Uint8Array(buffer).set(data.subarray(f.at,f.at+n));f.at+=n;return n},
 renameSync(a,b){assert.ok(files.has(a));files.set(b,files.get(a));files.delete(a)},unlinkSync:p=>files.delete(p)};
cache.set('@kit.CoreFileKit',{fileIo:io});cache.set('@kit.ArkTS',{util:{}});
cache.set('download/StorageBudget',{StorageBudget:{pin:p=>pins.set(p,(pins.get(p)||0)+1),unpin:p=>pins.set(p,pins.get(p)-1),admit(){},sync(){}}});
cache.set('core/network/NasConnection',{NasConnection:{shared:()=>({begin:()=>1,response(){},failed(){}})}});
cache.set('@kit.NetworkKit',{http:{RequestMethod:{GET:0},createHttp(){const handlers={};let rejectRequest;return{on:(k,f)=>handlers[k]=f,off:k=>delete handlers[k],destroy(){rejectRequest?.(Error('destroyed'))},requestInStream(){return new Promise((resolve,reject)=>{rejectRequest=reject;queueMicrotask(()=>{try{scenario(handlers,resolve,reject)}catch(e){reject(e)}})})}}}}});
function load(name){if(cache.has(name))return cache.get(name);const exports={};cache.set(name,exports);vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/'+name+'.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports,console,ArrayBuffer,Uint8Array,require:key=>load(key.startsWith('@')?key:path.posix.normalize(path.posix.join(path.posix.dirname(name),key)))});return exports}
const {HttpTransport}=load('core/network/HttpTransport'),{DownloadCancellation}=load('core/network/DownloadCancellation');
const chunk=(h,s)=>h.dataReceive(Uint8Array.from(bytes(s)).buffer);
async function run(work,offset=0,total=4,validator='',signal){scenario=work;return new HttpTransport().requestBinaryToFile('https://nas/image','/part',{},offset,total,undefined,undefined,validator,signal)}
function clean(){assert.equal(fds.size,0,'all file descriptors close');assert.ok([...pins.values()].every(n=>n===0),'all pins released');assert.equal(files.has('/part.incoming'),false,'no staging orphan')}
(async()=>{
 scenario=null;await run((h,resolve)=>{h.headersReceive({'status-line':'HTTP/1.1 200 OK','content-length':'4'});chunk(h,'DATA');h.dataEnd();resolve(200)});assert.equal(value('/part'),'DATA');assert.equal(reads,0,'normal headers-first path never copies the body');clean();
 put('/part','OLD');await run((h,resolve)=>{chunk(h,'DATA');assert.equal(value('/part'),'OLD','early body cannot touch old bytes');h.headersReceive({'status-line':'HTTP/1.1 200 OK','content-length':'4'});h.dataEnd();resolve(200)});assert.equal(value('/part'),'DATA');clean();
 // Device repro: a header event has Location but omits status-line. Final
 // response code arrives after data; this must not throw "headers not ready".
 await run((h,resolve)=>{h.headersReceive({Location:'https://nas/final','content-length':'4'});chunk(h,'DATA');h.dataEnd();resolve(200)});assert.equal(value('/part'),'DATA');clean();
 put('/part','OLD');const result=await run((h,resolve)=>{chunk(h,'NEW');assert.equal(value('/part'),'OLD');h.headersReceive({'status-line':'HTTP/1.1 206 Partial Content','content-range':'bytes 3-5/6','content-length':'3',etag:'"v1"'});h.dataEnd();resolve(206)},3,6,'"v1"');assert.equal(result.resumed,true);assert.equal(value('/part'),'OLDNEW');assert.ok(maxRead<=65536);clean();
 put('/part','OLD');await assert.rejects(run((h,resolve)=>{chunk(h,'BAD');h.headersReceive({'status-line':'HTTP/1.1 206 Partial Content','content-range':'bytes 3-5/6',etag:'"v2"'});h.dataEnd();resolve(206)},3,6,'"v1"'),e=>e.status===206);assert.equal(value('/part'),'OLD','wrong validator cannot append early body');clean();
 put('/part','OLD');await assert.rejects(run((h,resolve)=>{chunk(h,'HTML');h.headersReceive({'status-line':'HTTP/1.1 403 Forbidden'});h.dataEnd();resolve(403)}),e=>e.status===403);assert.equal(value('/part'),'OLD','error body cannot truncate the old target');clean();
 await run((h,resolve)=>{chunk(h,'DATA');h.dataEnd();resolve(200)});assert.equal(value('/part'),'DATA','missing header event falls back to final response code');clean();
 put('/part','OLD');const suffix='X'.repeat(1024*1024);await run((h,resolve)=>{chunk(h,suffix);h.headersReceive({'status-line':'HTTP/1.1 206 Partial Content','content-range':'bytes 3-'+(suffix.length+2)+'/'+(suffix.length+3),'content-length':String(suffix.length),etag:'"v1"'});h.dataEnd();resolve(206)},3,suffix.length+3,'"v1"');assert.equal(value('/part'),'OLD'+suffix);assert.ok(maxRead<=65536);clean();
 put('/part','OLD');const signal=new DownloadCancellation();await assert.rejects(run((h)=>{chunk(h,'HALF');signal.cancel()},0,9,'',signal),e=>e.status===499);assert.equal(value('/part'),'OLD');clean();
 console.log('PASS actual HTTP stream: headers/data reordering, missing final status-line/redirect header, no-copy normal path, validated bounded resume, wrong ETag/HTTP-error prefix protection, cancellation and cleanup');
})().catch(e=>{console.error(e);process.exitCode=1});

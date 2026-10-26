const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),ts=require(process.argv[2]);
const players=[],fds=new Set(),sources=[];let nextFd=4,createGate=null,init=true,sourceError=false,prepareError=false;
const later=()=>{let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve}};
const tick=async()=>{for(let i=0;i<30;i++)await Promise.resolve()};
class Player {
 constructor(){this.handlers={};this.state='idle';this.duration=180000;this.currentTime=0;this.releases=0;players.push(this)}
 on(n,fn){this.handlers[n]=fn}emit(n,...a){this.handlers[n]?.(...a)}
 set url(v){this.urlValue=v;if(init)queueMicrotask(()=>{this.state='initialized';this.emit('stateChange','initialized')})}
 async setMediaSource(src,strategy){this.networkSource=src;this.strategy=strategy;if(sourceError)throw Error('unauthorized');if(init){this.state='initialized';this.emit('stateChange','initialized')}}
 async prepare(){if(prepareError)throw Error('unsupported');assert.equal(this.state,'initialized');this.state='prepared';this.emit('stateChange','prepared')}
 async play(){this.state='playing';this.emit('stateChange','playing')}async pause(){this.state='paused';this.emit('stateChange','paused')}
 seek(ms){this.currentTime=ms;queueMicrotask(()=>this.emit('seekDone',ms))}
 async release(){this.releases++;this.state='released'}
}
const ex={};vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/media/AudioPlaybackManager.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:ex,console,queueMicrotask,setTimeout,clearTimeout,require:n=>{
if(n==='@kit.CoreFileKit')return{fileIo:{OpenMode:{READ_ONLY:0},async open(){const fd=nextFd++;fds.add(fd);return{fd}},closeSync(fd){assert.ok(fds.delete(fd));}}};
if(n==='../model/FileEntry')return{};
if(n==='@kit.MediaKit')return{media:{async createAVPlayer(){const p=new Player();if(createGate)await createGate;return p},createMediaSourceWithUrl(url,headers){const s={url,headers,offline:true,enableOfflineCache(v){this.offline=v}};sources.push(s);return s}}};throw Error(n);
}});
const {AudioPlaybackManager}=ex;
(async()=>{
const m=new AudioPlaybackManager(),times=[],errors=[];const callbacks=[v=>times.push(v),()=>{},()=>{},e=>errors.push(e)];
const descriptor={url:'https://nas.example/temporary',headers:{Authorization:'test'},fileName:'large.flac'};
await m.open(descriptor,...callbacks,64000);assert.equal(fds.size,0);assert.equal(sources[0].headers.Authorization,'test');assert.equal(sources[0].offline,false);assert.equal(players[0].strategy.preferredBufferDuration,8);assert.equal(players[0].currentTime,64000);await m.play();await m.pause();assert.equal(players[0].state,'paused');assert.equal(await m.seek(90000),true);assert.equal(times.at(-1),90000);
await m.open('/cached.flac',...callbacks);assert.equal(fds.size,1);assert.match(players[1].urlValue,/^fd:\/\//);players[0].emit('timeUpdate',44);assert.notEqual(times.at(-1),44);await m.release();assert.equal(fds.size,0);
const gate=later();createGate=gate.promise;const pending=m.open(descriptor,...callbacks);await tick();await m.release();gate.resolve();await pending;assert.equal(players.at(-1).releases,1);assert.equal(fds.size,0);createGate=null;
init=false;const waiting=m.open(descriptor,...callbacks);waiting.catch(()=>{});await tick();await m.release();await assert.rejects(waiting);assert.equal(players.at(-1).releases,1);init=true;
sourceError=true;await assert.rejects(m.open(descriptor,...callbacks),/unauthorized/);assert.equal(players.at(-1).releases,1);assert.equal(errors.length,0,'initialization error handled once by the caller');sourceError=false;
prepareError=true;await assert.rejects(m.open(descriptor,...callbacks),/unsupported/);assert.equal(players.at(-1).releases,1);prepareError=false;
await Promise.all([m.open(descriptor,...callbacks),m.open('/winner.flac',...callbacks)]);assert.equal(fds.size,1);await m.release();assert.equal(fds.size,0);
const index=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');const a=index.indexOf('  private async openAudioPlayer('),b=index.indexOf('  private async prepareAudioPresentation(',a),opening=index.slice(a,b);assert.doesNotMatch(opening,/ensureCachedFile\(entry\)/);assert.match(opening,/repository.downloadDescriptor\(entry.path\)/);assert.match(opening,/CacheManager.findExisting/);
const cap=index.slice(index.indexOf('  private captureContinuation('),index.indexOf('  private async restoreContinuation('));assert.doesNotMatch(cap,/audioLocalPath|source\.url|\.headers|downloadDescriptor/);assert.match(cap,/state.positionMs/);assert.match(cap,/snapshot.entries/);
console.log('PASS streaming audio: authenticated source without FD/full download, local reuse, seek/restore, pause, init cancellation/error, stale callbacks and continuation payload');
})().catch(e=>{console.error(e);process.exitCode=1});
// Actual page open method: verify receiver position/auth resolution and cancellation.
const pageSource=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');
function method(name){const start=pageSource.search(new RegExp('^  (?:private )?(?:async )?'+name+'\\(','m'));assert.ok(start>=0,name);const rest=pageSource.slice(start+1),end=rest.search(/^  (?:private |@Builder|aboutTo|onBackPress\(|build\()/m);return pageSource.slice(start,start+1+end)}
async function pageChecks(){
 let cached='',scope='A',descriptorGate=null;const descriptor={url:'https://receiver/own-session',headers:{Auth:'receiver'}};
 const pageExports={};vm.runInNewContext(ts.transpileModule('export class Page {\n'+['openAudioPlayer','audioPageBusy','updateAudioSession'].map(method).join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:pageExports,console,Date,setTimeout,clearTimeout,getContext:()=>({}),AudioCoverRect:class{},AudioPlayerPolicy:{title:n=>n.replace(/\.[^.]+$/,'')},CacheManager:{findExisting:()=>cached},ContinuationManager:{shared:()=>({refresh(){}})}});
 const entry={path:'/Music/a.flac',name:'a.flac',size:100000000};
 function page(){const p=new pageExports.Page();Object.assign(p,{isBusy:false,audioOwnsBusy:false,audioOpening:false,audioClosing:false,audioOpenToken:0,audioEntryCloseRequested:false,showAudioPlayer:false,showSearch:false,entries:[entry],audioQueueSource:{replace(){}},currentRootType:3,currentPath:'/Music',autoPlayOnOpen:true,backgroundAudioPlayback:true,playbackBackgroundActive:false,cacheDirectory:'/cache',audioMode:'order',audioSessionUpdatedAt:0,
 repository:{sessionIdentity:()=>scope,async downloadDescriptor(path){p.descriptorCalls++;assert.equal(path,entry.path);if(descriptorGate)await descriptorGate;return descriptor}},descriptorCalls:0,opens:[],plays:0,errors:[],closed:0,
 isAudio:()=>true,async ensurePlaybackState(){},async confirmMeteredDownload(){return true},closeActionMenu(){},async ensureCacheState(){},originalCacheKey:()=>scope+entry.path,currentThumbnailSurface:()=> 'list',previewUri:()=>'',animateOpenAudioPlayer:async()=>{},async prepareAudioPresentation(){},finishCloseAudioPlayer(){p.closed++},reportError(e){p.errors.push(e)},ensureCachedFile(){throw Error('whole-file download forbidden')},
 audioManager:{async release(){},async open(...args){p.opens.push(args);args[2](180000);args[3]('prepared')},async play(){p.plays++}},audioSession:{async close(){},async open(){},update(){}}});return p;}
 let p=page();await p.openAudioPlayer(entry,false,97531,false,()=>true);assert.equal(p.descriptorCalls,1);assert.equal(p.opens[0][0],descriptor);assert.equal(p.opens[0][5],97531);assert.equal(p.plays,0,'paused continuation stays paused');assert.equal(p.audioLocalPath,'');
 cached='/cache/song.flac';p=page();await p.openAudioPlayer(entry);assert.equal(p.descriptorCalls,0);assert.equal(p.opens[0][0],cached);assert.equal(p.plays,1);cached='';
 const gate=later();descriptorGate=gate.promise;p=page();const opening=p.openAudioPlayer(entry);await tick();p.audioOpenToken++;gate.resolve();await opening;assert.equal(p.opens.length,0,'Back while minting URL prevents stale playback');descriptorGate=null;
 const change=later();descriptorGate=change.promise;p=page();const old=p.openAudioPlayer(entry);await tick();scope='B';change.resolve();await old;assert.equal(p.opens.length,0,'account change cannot install a URL');descriptorGate=null;
 const cancel=later();descriptorGate=cancel.promise;p=page();let valid=true;const restoring=p.openAudioPlayer(entry,false,97531,true,()=>valid);await tick();valid=false;cancel.resolve();await restoring;assert.equal(p.opens.length,0);assert.equal(p.closed,1);descriptorGate=null;
 p=page();p.showAudioPlayer=true;p.audioBackgrounded=true;p.isBusy=true;await p.openAudioPlayer(entry,true);assert.equal(p.opens.length,1,'background queue may advance while directory is busy');assert.equal(p.audioBackgrounded,true);assert.equal(p.isBusy,true,'background track change cannot release directory busy ownership');
 p=page();p.showAudioPlayer=true;p.audioBackgrounded=true;p.audioOriginScope=scope;p.audioEntry={...entry};p.onAudioPlaybackNavigationRequested=()=>{p.restored=true};await p.openAudioPlayer(entry);assert.equal(p.restored,true);assert.equal(p.opens.length,0,'same account/version restores the existing player');
 p=page();p.showAudioPlayer=true;p.audioBackgrounded=true;p.audioOriginScope=scope;p.audioEntry={...entry,modifiedTime:1};p.originalCacheKey=e=>scope+e.path+'|'+e.modifiedTime;let flights=0;p.animateOpenAudioPlayer=async()=>{flights++};await p.openAudioPlayer({...entry,modifiedTime:2});assert.equal(p.opens.length,1,'replaced file must not reuse the old player');assert.equal(p.audioBackgrounded,false);assert.equal(flights,1,'a newly opened foreground track retains the normal cover entry animation');
 console.log('PASS actual audio page: receiver mints its own source, restores paused position, cached route, Back/account/continuation cancellation');
}
pageChecks().catch(e=>{console.error(e);process.exitCode=1});

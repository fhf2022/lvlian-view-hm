const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),ts=require(process.argv[2]);
const cache=new Map(),decodes=[],sessions=[];
const tick=async()=>{for(let i=0;i<30;i++)await Promise.resolve()};
function bitmap(label){return {label,releases:0,async release(){this.releases++}}}
function session(){const s={sessionId:'test',sessionType:'video',metadata:[],destroyed:false,on(){},async activate(){},async deactivate(){},async destroy(){this.destroyed=true},async setBackgroundPlayMode(){},async setExtras(){},async setLaunchAbility(){},async setAVMetadata(m){assert.ok(!this.destroyed);this.metadata.push(m)},async setAVQueueTitle(){},async setAVQueueItems(){},async setAVPlaybackState(){}};sessions.push(s);return s;}
function load(name){
 if(name==='@kit.AbilityKit')return{wantAgent:{OperationType:{START_ABILITIES:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:1},async getWantAgent(){return {}}}};
 if(name==='@kit.ImageKit')return{};
 if(name==='@kit.AVSessionKit')return{avSession:{async createAVSession(){return session()},BackgroundPlayMode:{ENABLE_BACKGROUND_PLAY:1},ProtocolType:{TYPE_CAST_PLUS_STREAM:1,TYPE_DLNA:2},PlaybackState:{PLAYBACK_STATE_PREPARE:0,PLAYBACK_STATE_PAUSE:1,PLAYBACK_STATE_PLAY:2}}};
 if(name==='media/SessionArtwork')return{SessionArtwork:{decode(uri,square){let resolve;const p=new Promise(r=>resolve=r);decodes.push({uri,square,resolve});return p}}};
 if(cache.has(name))return cache.get(name);const exports={};cache.set(name,exports);vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/'+name+'.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}}).outputText,{exports,console,Observed:c=>c,require:key=>load(key.startsWith('.')?path.posix.normalize(path.posix.join(path.posix.dirname(name),key)):key)});return exports;
}
const {VideoMediaSessionManager}=load('media/VideoMediaSessionManager');const {FileEntry}=load('model/FileEntry');
const entry=i=>Object.assign(new FileEntry(),{path:'/video/'+i,name:i+'.mp4',size:4000});
const snapshot={prepared:true,playing:true,durationMs:90000,positionMs:3000,playbackRate:1,bufferingPercent:100};
const callbacks={onPlay(){},onPause(){},onStop(){},onNext(){},onSeek(){}};const context={abilityInfo:{bundleName:'test',name:'Entry'}};
(async()=>{
 const m=new VideoMediaSessionManager();const opening=m.open(context,entry(1),entry(2),snapshot,callbacks,'file:///cover1.jpg');await tick();assert.equal(decodes[0].square,false);const cover1=bitmap('1');decodes[0].resolve(cover1);await opening;assert.equal(sessions[0].metadata[0].mediaImage,cover1);
 m.setArtwork(entry(1),'file:///late1.jpg');await tick();const old=bitmap('old');
 const next=m.open(context,entry(2),null,snapshot,callbacks,'file:///cover2.jpg');await tick();decodes[1].resolve(old);await tick();assert.equal(old.releases,1,'obsolete decode is released');const cover2=bitmap('2');decodes[2].resolve(cover2);await next;assert.equal(sessions[0].metadata.at(-1).assetId,entry(2).path);assert.equal(sessions[0].metadata.at(-1).mediaImage,cover2);assert.equal(cover1.releases,1);
 const count=decodes.length;m.setArtwork(entry(1),'file:///wrong.jpg');await tick();assert.equal(decodes.length,count,'previous file cannot publish a late thumbnail');
 m.setArtwork(entry(2),'file:///late2.jpg');await tick();await m.close();const afterClose=bitmap('late');decodes.at(-1).resolve(afterClose);await tick();assert.equal(afterClose.releases,1);assert.equal(cover2.releases,1);assert.equal(sessions[0].metadata.length,2);
 const noCover=new VideoMediaSessionManager();const opened=noCover.open(context,entry(3),null,snapshot,callbacks);await tick();decodes.at(-1).resolve(null);await opened;assert.equal(sessions[1].metadata[0].title,'3.mp4');assert.ok(!('mediaImage' in sessions[1].metadata[0]),'undefined image must be omitted');await noCover.close();
 const index=fs.readFileSync('entry/src/main/ets/pages/Index.ets','utf8');const start=index.indexOf('private async publishThumbnailPreview('),end=index.indexOf('private releaseFileThumbnailBitmap(',start);assert.match(index.slice(start,end),/videoMediaSession.setArtwork/);
 console.log('PASS video metadata: PixelMap artwork, late thumbnail, switch/close races, bounded ownership, no-cover playback');
})().catch(e=>{console.error(e);process.exitCode=1});

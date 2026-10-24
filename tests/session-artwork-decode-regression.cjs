const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),ts=require(process.argv[2]);
let dimensions={width:4000,height:2000},fdFailure=false,size=100,shortRead=false,created=[],files=0,closed=0,sources=0,released=0;
const image={PixelMapFormat:{RGBA_8888:1},createImageSource(input){sources++;return{async getImageInfo(){return{size:dimensions}},async createPixelMap(options){if(typeof input==='number'&&fdFailure)throw Error('FD decode');const bm={size:options.desiredSize,crops:0,scales:0,releases:0,async getImageInfo(){return{size:this.size}},async crop(r){this.crops++;this.size=r.size},async scale(x,y){this.scales++;this.size={width:this.size.width*x,height:this.size.height*y}},async release(){this.releases++}};created.push(bm);return bm},async release(){released++}}}};
const fileIo={OpenMode:{READ_ONLY:0},async open(){files++;return{fd:1}},async close(){closed++},async stat(){return{size}},async read(fd,b,o){return shortRead?0:o.length}};
const ex={};vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/media/SessionArtwork.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports:ex,console,Uint8Array,require:key=>key==='@kit.ImageKit'?{image}:{fileIo,fileUri:{FileUri:class{constructor(uri){this.path=uri.replace('file://','')}}}}});
(async()=>{
const {SessionArtwork}=ex;
const video=await SessionArtwork.decode('file:///video.jpg',false);assert.equal(JSON.stringify(video.size),JSON.stringify({width:800,height:400}));assert.equal(video.crops,0);await video.release();
const music=await SessionArtwork.decode('/audio.jpg');assert.equal(JSON.stringify(music.size),JSON.stringify({width:400,height:400}));assert.equal(music.crops,1);await music.release();
dimensions={width:128,height:128};const small=await SessionArtwork.decode('/small.jpg');assert.equal(small.scales,1);assert.equal(small.size.width,300);await small.release();
fdFailure=true;const fallback=await SessionArtwork.decode('/fallback.jpg',false);assert.ok(fallback);await fallback.release();
shortRead=true;assert.equal(await SessionArtwork.decode('/truncated.jpg'),null);shortRead=false;size=3*1024*1024;assert.equal(await SessionArtwork.decode('/large-fallback.jpg'),null);
assert.equal(files,closed);assert.equal(sources,released);assert.equal(await SessionArtwork.decode(''),null);assert.equal(files,closed);
console.log('PASS shared artwork decode: proportional video, square music/minimum, 800px bound, FD fallback, truncated/oversized input and resource cleanup');
})().catch(e=>{console.error(e);process.exitCode=1});

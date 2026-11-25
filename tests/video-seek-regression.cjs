const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const source = fs.readFileSync('entry/src/main/ets/media/VideoPlaybackManager.ets', 'utf8');
const page = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
const timeline = page.match(/private videoBufferedTimelineMs\(\): number \{[\s\S]*?\n  \}/)[0];
const exportsObject = {};
const events = new Map();
const seekRequests = [];
const player = {
  state: 'playing',
  on: (event, handler) => events.set(event, handler),
  seek: (...args) => seekRequests.push(args),
  release: async () => {},
};
const buffering = { BUFFERING_START: 1, BUFFERING_PERCENT: 2, BUFFERING_END: 3, CACHED_DURATION: 4 };
const media = { createAVPlayer: async () => player, BufferingInfoType: buffering, SeekMode: { SEEK_CLOSEST: 2 } };

vm.runInNewContext(ts.transpileModule(source + '\nexport class Timeline {\n' + timeline + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText, {
  exports: exportsObject,
  require: name => {
    if (name === '@kit.MediaKit') { return { media }; }
    assert.ok(['@kit.CoreFileKit', '@kit.AudioKit'].includes(name));
    return {};
  },
});

async function checkSeek() {
  const manager = new exportsObject.VideoPlaybackManager();
  const model = new exportsObject.Timeline();
  model.videoDurationMs = 60_000;
  model.videoCurrentMs = 10_000;
  model.videoBufferedUntilMs = 0;
  const progress = [];
  const cachedUntil = [];
  await manager.open({}, 10_000, {
    onDuration: () => {},
    onBuffering: percent => progress.push(percent),
    onBufferedUntil: timeMs => {
      cachedUntil.push(timeMs);
      model.videoBufferedUntilMs = Math.max(model.videoBufferedUntilMs, timeMs);
    },
  }, false);
  manager.configured = true;
  events.get('durationUpdate')(60_000);
  events.get('bufferingUpdate')(buffering.CACHED_DURATION, 12_000);
  assert.equal(model.videoBufferedTimelineMs(), 22_000);

  manager.seek(35_000);
  model.videoCurrentMs = 35_000;
  assert.deepEqual(seekRequests, [[35_000, media.SeekMode.SEEK_CLOSEST]]);
  const expectedPosition = model.videoBufferedTimelineMs();
  for (const [type, value] of [[buffering.BUFFERING_PERCENT, 100], [buffering.BUFFERING_START, 0],
    [buffering.BUFFERING_END, 0]]) {
    events.get('bufferingUpdate')(type, value);
    assert.equal(model.videoBufferedTimelineMs(), expectedPosition);
  }
  assert.deepEqual(progress.slice(-3), [100, 0, 100]);
  assert.deepEqual(cachedUntil, [22_000]);
  assert.ok(!timeline.includes('videoBufferingPercent'));
  await manager.release();
  console.log('PASS seek uses accurate frames and loading percentages do not move the timeline');
}

checkSeek().catch(error => {
  console.error(error);
  process.exitCode = 1;
});

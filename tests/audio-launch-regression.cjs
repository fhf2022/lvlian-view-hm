const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const registry = new Map();
const wantAgent = {
  OperationType: { START_ABILITIES: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
  getWantAgent: async options => {
    const key = options.actionType + ':' + options.requestCode;
    let agent = registry.get(key);
    if (!agent) { agent = {}; registry.set(key, agent); }
    agent.wants = options.wants;
    return agent;
  }
};
function compile(source, imports, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, { exports, require: name => {
    assert.ok(Object.hasOwn(imports, name), name);
    return imports[name];
  }, console, ...globals });
  return exports;
}
let audioAgent, videoAgent;
const session = {
  on() {}, async activate() {}, async deactivate() {}, async destroy() {},
  async setAVMetadata() {}, async setLaunchAbility(agent) { audioAgent = agent; }
};
const { AudioSessionManager } = compile(fs.readFileSync('entry/src/main/ets/media/AudioSessionManager.ets', 'utf8'), {
  '@kit.AbilityKit': { wantAgent }, '@kit.AVSessionKit': { avSession: { createAVSession: async () => session } },
  './SessionArtwork': { SessionArtwork: { decode: async () => null } },
  './VideoBackgroundTaskManager': { VideoBackgroundTaskManager: class { async release() {} } }
});
const videoSource = fs.readFileSync('entry/src/main/ets/media/VideoMediaSessionManager.ets', 'utf8');
const start = videoSource.indexOf('  private async setLaunchAbility(');
const next = videoSource.slice(start + 1).search(/^  (?:private |[a-zA-Z])/m);
assert.ok(start >= 0 && next > 0);
// The isolated production method needs the same native WantAgent registry.
const { Video } = compile('export class Video {\n' + videoSource.slice(start, start + next + 1) + '\n}', {}, { wantAgent });
(async () => {
  const audio = new AudioSessionManager(), context = { abilityInfo: { bundleName: 'cn.fhf.linkfiles', name: 'EntryAbility' } };
  await audio.open(context, '/music/a.flac', 'a', '', '', {});
  assert.equal(audioAgent.wants[0].parameters.audioPlaybackEntry, true);
  await new Video().setLaunchAbility(context, { setLaunchAbility: async agent => { videoAgent = agent; } });
  assert.notEqual(audioAgent, videoAgent, 'video launch configuration must not overwrite a music restore card');
  assert.equal(audioAgent.wants[0].parameters.audioPlaybackEntry, true);
  assert.equal(videoAgent.wants[0].parameters, undefined);
  await audio.close();
  console.log('PASS actual audio/video system-card launch: separate WantAgent identity and correct audio restore parameter');
})().catch(error => { console.error(error); process.exitCode = 1; });

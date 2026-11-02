// Run the production startup gate and native album authorization with mocked system services.
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
function load(path, dependencies) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports, require(name) {
    assert.ok(Object.hasOwn(dependencies, name), 'unexpected startup/system dependency: ' + name);
    return dependencies[name];
  }, console: { info() {}, warn() {} } });
  return exports;
}
const privacy = {
  AppPrivacyType: { PRIVACY_AGREEMENT: 1 }, AppPrivacyLinkType: { PRIVACY_STATEMENT_LINK: 1 },
  AppPrivacyResultType: { FULL_MODE_AGREED: 1 }, AppPrivacyMgmtType: { FULL_MODE: 1 },
  getAppPrivacyMgmtInfo: () => ({ type: 1, privacyInfo: [{ type: 1, versionCode: 2 }] }),
  getAppPrivacyResult: () => []
};
let consentCalls = 0, backgroundInitializations = 0, notifications = 0;
const agreed = (version = 2) => [{ type: 1, result: 1, versionCode: version }];
privacy.requestAppPrivacyConsent = async () => { consentCalls++; return { results: agreed() }; };
const background = { initialize() { backgroundInitializations++; }, async requestNotificationPermission() { notifications++; } };
const { StartupAuthorization: Startup } = load('entry/src/main/ets/core/authorization/StartupAuthorization.ets', {
  '@kit.AbilityKit': {}, '@kit.AppGalleryKit': { privacyManager: privacy },
  '../../transfer/TransferBackgroundManager': { TransferBackgroundManager: { shared: () => background } }
});
let permissionCalls = 0, settingsCalls = 0, mediaReads = 0;
let response = { authResults: [0] }, settingsResult = [0];
const { LocalAlbumSource: Albums } = load('entry/src/main/ets/upload/LocalAlbumSource.ets', {
  '@kit.AbilityKit': { abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0, PERMISSION_DENIED: -1 }, createAtManager: () => ({
    requestPermissionsFromUser: async (_context, permissions) => {
      assert.equal(permissions.join(','), 'ohos.permission.READ_IMAGEVIDEO'); permissionCalls++; return response;
    }, requestPermissionOnSetting: async () => { settingsCalls++; return settingsResult; }
  }) } },
  '@kit.MediaLibraryKit': { photoAccessHelper: { getPhotoAccessHelper() { mediaReads++; throw new Error('unexpected read'); } } },
  '@kit.ArkData': {}, '@kit.ArkTS': {}, './AlbumUploadModel': {}
});
(async () => {
  // Fresh install: consent, then normal app use, with no dependency on gallery or its old preference flag.
  const gate = new Startup(); gate.prepare(); const ready = gate.waitForInitial();
  await gate.beginInitial({}); assert.equal(await ready, true);
  assert.equal(consentCalls, 1); assert.equal(backgroundInitializations, 1);
  assert.equal(permissionCalls, 0); assert.equal(mediaReads, 0);
  // Upgrades, relaunches and permission revocation do not make startup request gallery access.
  privacy.getAppPrivacyResult = () => agreed();
  for (let i = 0; i < 3; i++) assert.equal(await new Startup().authorize({}), true);
  assert.equal(consentCalls, 1); assert.equal(permissionCalls, 0); assert.equal(mediaReads, 0);
  const beforeDenied = backgroundInitializations;
  privacy.getAppPrivacyResult = () => [];
  privacy.requestAppPrivacyConsent = async () => ({ results: [] });
  assert.equal(await new Startup().authorize({}), false);
  assert.equal(backgroundInitializations, beforeDenied, 'declining privacy does not initialize app services');
  privacy.getAppPrivacyResult = () => agreed(1);
  let resolve;
  privacy.requestAppPrivacyConsent = () => { consentCalls++; return new Promise(r => { resolve = r; }); };
  const pending = new Startup(), first = pending.authorize({}), duplicate = pending.authorize({});
  assert.equal(first, duplicate); resolve({ results: agreed() }); assert.equal(await first, true);
  assert.equal(permissionCalls, 0);
  privacy.getAppPrivacyMgmtInfo = () => { throw new Error('privacy service unavailable'); };
  assert.equal(await new Startup().authorize({}), false); assert.equal(permissionCalls, 0);

  // The explicit album action still invokes the official prompt; a fresh denial ends this attempt.
  const albums = new Albums({}); assert.equal(permissionCalls, 0); assert.equal(mediaReads, 0);
  await albums.requestPermission(true); assert.equal(permissionCalls, 1);
  response = { authResults: [-1], dialogShownResults: [true] };
  await assert.rejects(albums.requestPermission(true), /需要允许读取图片/); assert.equal(settingsCalls, 0);
  response = { authResults: [-1], dialogShownResults: [false] };
  await albums.requestPermission(true); assert.equal(settingsCalls, 1);
  settingsResult = [-1];
  await assert.rejects(albums.requestPermission(true), /需要允许读取图片/); assert.equal(settingsCalls, 2);
  assert.equal(mediaReads, 0, 'permission handling does not read the album');
  console.log('PASS startup consent: fresh/upgrade/relaunch have no gallery request or read; privacy denial/version/error and deduplication; explicit album prompt, fresh refusal and official settings recovery');
})().catch(error => { console.error(error); process.exitCode = 1; });

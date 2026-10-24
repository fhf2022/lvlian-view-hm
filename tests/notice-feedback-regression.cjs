// node tests/notice-feedback-regression.cjs <SDK typescript.js>
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require(process.argv[2]);
const page = fs.readFileSync('entry/src/main/ets/pages/Index.ets', 'utf8');
function transpile(source, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: {target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS}
  }).outputText, {exports, Math, console, ...globals});
  return exports;
}
const {GlassControlGeometry: Glass} = transpile(fs.readFileSync('entry/src/main/ets/ui/GlassControlGeometry.ets', 'utf8'));
const names = ['bottomSafeInset', 'floatingBarBottomMargin', 'floatingBarContentInset',
  'showImmersiveToast', 'presentErrorMessage', 'onContinuationNoticeChanged', 'onContinuationMessage'];
function method(name) {
  const start = page.search(new RegExp('^  private (?:async )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, name);
  const end = page.slice(start + 1).search(/^  (?:private |@Builder)/m);
  return page.slice(start, start + end + 1);
}
const storage = new Map(); let haptics = 0, now = 10000, failToast = false;
const {Page} = transpile('export class Page {\n' + names.map(method).join('\n') + '\n}', {
  Glass, FLOATING_BAR_CONTENT_EXTRA_VP: 32,
  HapticFeedback: {failure: () => haptics++},
  AppStorage: {setOrCreate: (key, value) => storage.set(key, value)}
});
const h = new Page(), toasts = [], material = {};
Object.assign(h, {
  noticeMessage: '', noticeShownAt: 0, navigationBarHeightPx: 56,
  startupAuthorized: true, startupRestoring: false, continuationSending: false,
  continuationPending: false, continuationWaitingForAccount: false, continuationNoticeStage: '',
  abilityInBackground: false, gestureSharePageVisible: true, floatingPanelMaterial: material,
  getMonotonicNow: () => now,
  getUIContext: () => ({px2vp: value => value / 2, getPromptAction: () => ({
    showToast: options => {if (failToast) throw new Error('missing window'); toasts.push(options);}
  })})
});
assert.equal(h.showImmersiveToast('  已加入下载  '), true);
assert.equal(toasts.at(-1).message, '已加入下载');
assert.equal(toasts.at(-1).duration, 2000);
assert.equal(toasts.at(-1).systemMaterial, material, 'reuse the existing native glass material');
assert.equal(toasts.at(-1).bottom + h.bottomSafeInset(), h.floatingBarContentInset(12),
  'native Toast adds the navigation inset once; leave exactly 12vp above the toolbar');
assert.equal(h.showImmersiveToast('已加入下载'), false, 'coalesce repeated callbacks within the visible lifetime');
now += 2000;
assert.equal(h.showImmersiveToast('已加入下载'), true, 'a later independent action may repeat its feedback');
h.navigationBarHeightPx = 0;
assert.equal(h.showImmersiveToast('分屏'), true);
assert.equal(toasts.at(-1).bottom, 16 + Glass.barHeight + 12, 'upper split/floating windows retain edge clearance');
assert.equal(h.showImmersiveToast(' '), false);

h.presentErrorMessage('连接中断', '上传失败');
assert.equal(toasts.at(-1).message, '上传失败：连接中断');
assert.equal(haptics, 1);
h.presentErrorMessage('连接中断', '上传失败');
assert.equal(haptics, 1, 'a repeated error does not keep vibrating or opening modal dialogs');
h.presentErrorMessage('下载失败，请重试', '下载失败');
assert.equal(toasts.at(-1).message, '下载失败，请重试', 'do not duplicate a title already in the message');

h.startupRestoring = true; h.continuationPending = true;
const beforeStartup = toasts.length;
h.onContinuationNoticeChanged();
assert.equal(toasts.length, beforeStartup, 'defer receipt feedback until the startup/privacy gate is ready');
h.startupRestoring = false; h.abilityInBackground = true;
h.onContinuationNoticeChanged();
assert.equal(toasts.length, beforeStartup, 'do not consume pending feedback while backgrounded');
h.abilityInBackground = false;
h.onContinuationNoticeChanged();
assert.equal(toasts.length, beforeStartup, 'receiver restoration uses its logo cover, not the source notification');
const receivingCount = toasts.length;
h.onContinuationNoticeChanged(); now += 5000; h.onContinuationNoticeChanged();
assert.equal(toasts.length, receivingCount, 'receiver refreshes do not recreate notifications');
h.continuationWaitingForAccount = true; h.onContinuationNoticeChanged();
assert.equal(toasts.at(-1).message, '请登录相同的 NAS 和账号以接续');
h.continuationPending = false; h.onContinuationNoticeChanged();
assert.equal(h.continuationNoticeStage, '', 'completion/cancellation releases the receipt stage');
h.continuationSending = true; h.continuationWaitingForAccount = false;
const beforeSending = toasts.length; h.onContinuationNoticeChanged();
assert.equal(toasts.length, beforeSending + 1, 'original device must show the glass notification');
assert.equal(toasts.at(-1).message, '正在流转到另一设备');
h.onContinuationNoticeChanged(); now += 3000; h.onContinuationNoticeChanged();
assert.equal(toasts.length, beforeSending + 1, 'source notification appears once per export');
h.continuationSending = false; h.onContinuationNoticeChanged();
assert.equal(h.continuationNoticeStage, '');
h.continuationMessage = '接续恢复失败'; h.abilityInBackground = true;
storage.set('continuationMessage', h.continuationMessage); h.onContinuationMessage();
assert.equal(storage.get('continuationMessage'), '接续恢复失败', 'retain a background failure until foreground');
h.abilityInBackground = false; h.onContinuationMessage();
assert.equal(storage.get('continuationMessage'), '');
assert.equal(toasts.at(-1).message, '接续恢复失败');
failToast = true;
assert.equal(h.showImmersiveToast('窗口已销毁'), false, 'a disappearing window must not reject the originating operation');
assert.ok(page.includes('(this.continuationPending && !this.continuationWaitingForAccount)'),
  'hot and cold receivers both retain the app-logo placeholder until restored');
assert.ok(!page.includes('if (!this.startupAuthorized || this.startupRestoring || this.continuationSending)'),
  'export must retain the current file/media page, never replace it with the splash');
assert.ok(!page.includes('showErrorDialog') && !page.includes('errorDialogShowing'), 'ordinary errors use the shared notification path');
console.log('PASS: native glass feedback — source notification, receiver logo placeholder, 2s lifetime, toolbar/navigation spacing, duplicate errors, account/startup/background gating and destroyed windows');

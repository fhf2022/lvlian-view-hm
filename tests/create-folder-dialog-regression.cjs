const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const source = fs.readFileSync('entry/src/main/ets/components/CreateFolderDialog.ets', 'utf8');
const methods = source.slice(source.indexOf('  aboutToAppear()'), source.indexOf('  @Builder'));
const ex = {};
class Controller { constructor() { this.closes = 0; } close() { this.closes++; } }
vm.runInNewContext(ts.transpileModule('export class Dialog {\n' + methods + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { exports: ex, promptAction: { DialogController: Controller },
  DialogAlignment: { Center: 1 }, KeyboardAvoidMode: { DEFAULT: 0 },
  TaskPanelStyle: { dialogWidth: w => Math.min(420, w * .84, Math.max(0, w - 32)) },
  console: { warn() {} } });
const tick = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function make(width = 360) {
  const p = new ex.Dialog(), opened = [];
  Object.assign(p, { visible: true, busy: false, viewportWidth: width, mounted: false,
    dialogController: null, Content() {},
    onClose() { p.cancelled = (p.cancelled || 0) + 1; p.visible = false; p.syncVisible(); },
    getUIContext: () => ({ getPromptAction: () => ({ presentCustomDialog(builder, controller, options) {
      builder();
      return new Promise((resolve, reject) => opened.push({ controller, options, resolve, reject }));
    } }) }) });
  p.aboutToAppear();
  return { p, opened };
}
(async () => {
  for (const width of [360, 1280]) {
    const s = make(width), first = s.opened[0];
    assert.equal(first.options.alignment, 1, 'phone and tablet use native Center alignment');
    assert.ok(first.options.width <= 420);
    assert.equal(first.options.keyboardAvoidMode, 0);
    first.resolve(1); await tick();
    let dismissals = 0;
    s.p.busy = true;
    first.options.onWillDismiss({ dismiss() { dismissals++; } });
    assert.equal(dismissals, 0, 'live busy state prevents Back/outside cancellation');
    s.p.busy = false;
    first.options.onWillDismiss({ dismiss() { dismissals++; } });
    assert.equal(dismissals, 1); assert.equal(s.p.visible, false);
  }
  const late = make(), old = late.opened[0];
  late.p.visible = false; late.p.syncVisible();
  late.p.visible = true; late.p.syncVisible();
  const next = late.opened[1];
  old.resolve(1); await tick();
  assert.ok(old.controller.closes > 0, 'late opening is closed after parent cancellation');
  old.options.onDidDisappear();
  old.options.onWillDismiss({ dismiss() {} });
  assert.equal(late.p.visible, true, 'stale native lifecycle cannot close the new dialog');
  assert.equal(late.p.dialogController, next.controller);
  late.p.aboutToDisappear(); next.resolve(2); await tick();
  assert.ok(next.controller.closes > 0, 'unmounted owner cannot leave a native input layer');
  const failed = make(); failed.opened[0].reject(new Error('open failed')); await tick();
  assert.equal(failed.p.visible, false);
  assert.equal(failed.p.dialogController, null);
  console.log('PASS create-folder dialog: centered phone/tablet, keyboard policy, busy cancellation, late opens, stale callbacks and unmount');
})().catch(error => { console.error(error); process.exitCode = 1; });

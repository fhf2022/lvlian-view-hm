import { promptAction, uiMaterial } from '@kit.ArkUI'
import { TaskPanelStyle } from '../ui/TaskPanelStyle'
import { ContentDivider } from './ContentDivider'

/**
 * 统一的名字输入弹窗：新建文件夹、目标目录新建、重命名共用一套外观与生命周期。
 *
 * 调用方只负责持有「目标 + 请求」（要建哪个目录、要给哪个条目改名），
 * 弹窗本身负责原生 dialog 的打开/关闭、忙碌态禁用、晚到回调与卸载兜底。
 * 标题、占位符和控件 id 前缀由调用方注入，避免每加一个入口就复制一份 UI。
 */
@Component
export struct NameInputDialog {
  @Link @Watch('syncVisible') visible: boolean
  @Link name: string
  @Prop title: string = ''
  @Prop placeholder: string = ''
  @Prop idPrefix: string = 'name-input'
  @Prop busy: boolean = false
  @Prop viewportWidth: number = 360
  @Prop material: uiMaterial.Material = uiMaterial.Material.empty
  onClose: () => void = () => {}
  onConfirm: () => void = () => {}
  private dialogController: promptAction.DialogController | null = null
  private mounted: boolean = false

  aboutToAppear(): void { this.mounted = true; this.syncVisible() }
  aboutToDisappear(): void { this.mounted = false; this.closeDialog() }

  private closeDialog(): void {
    const controller = this.dialogController
    this.dialogController = null
    controller?.close()
  }

  private syncVisible(): void {
    if (!this.mounted || !this.visible) { this.closeDialog(); return }
    if (this.dialogController !== null) { return }
    const controller = new promptAction.DialogController()
    this.dialogController = controller
    this.getUIContext().getPromptAction().presentCustomDialog(() => { this.Content() }, controller, {
      alignment: DialogAlignment.Center, width: TaskPanelStyle.dialogWidth(this.viewportWidth),
      cornerRadius: 24, keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
      autoCancel: true, systemMaterial: this.material,
      onWillDismiss: (action: DismissDialogAction): void => {
        if (this.dialogController !== controller) { action.dismiss(); return }
        if (this.busy) { return }
        this.dialogController = null
        action.dismiss(); this.onClose()
      },
      onDidDisappear: (): void => {
        if (this.dialogController !== controller) { return }
        this.dialogController = null
        if (this.mounted && this.visible) { this.onClose() }
      }
    }).then((): void => {
      // Parent dismissal/continuation can happen before the native dialog opens.
      if (this.dialogController !== controller || !this.visible || !this.mounted) { controller.close() }
    }).catch((error: Error): void => {
      if (this.dialogController === controller) { this.dialogController = null; this.onClose() }
      console.warn('[NameInputDialog] open failed: ' + JSON.stringify(error))
    })
  }

  @Builder
  Content(): void {
    Column({ space: 14 }) {
      Text(this.title).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary')).width('100%')
      Column({ space: 2 }) {
        TextInput({ placeholder: this.placeholder, text: this.name })
          .height(40).fontSize(16).fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent)
          .border({ width: 0, color: Color.Transparent, radius: 0 })
          .padding({ left: 14, right: 14 }).enabled(!this.busy)
          .onChange((value: string) => { this.name = value })
          .id(this.idPrefix + '-name')
        ContentDivider({ startInset: 14, endInset: 14 })
      }
      Row({ space: 8 }) {
        Button('取消').layoutWeight(1).height(42).fontSize(15)
          .fontColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent)
          .stateEffect(false).enabled(!this.busy)
          .onClick(() => this.onClose()).id(this.idPrefix + '-cancel')
        Button(this.busy ? '处理中…' : '确定').layoutWeight(1).height(42).fontSize(15)
          .fontColor('#2E6BFF').backgroundColor(Color.Transparent)
          .stateEffect(false).enabled(!this.busy)
          .onClick(() => this.onConfirm()).id(this.idPrefix + '-confirm')
      }.width('100%')
    }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 12 })
      .borderRadius(24).backgroundColor(Color.Transparent).id(this.idPrefix + '-content')
  }

  build() {
    Column() {}.width(0).height(0)
  }
}

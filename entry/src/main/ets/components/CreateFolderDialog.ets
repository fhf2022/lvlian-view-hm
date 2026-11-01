import { promptAction, uiMaterial } from '@kit.ArkUI'
import { TaskPanelStyle } from '../ui/TaskPanelStyle'
import { ContentDivider } from './ContentDivider'

/** Both entry points own their target and request; this component owns the dialog. */
@Component
export struct CreateFolderDialog {
  @Link @Watch('syncVisible') visible: boolean
  @Link name: string
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
      console.warn('[CreateFolderDialog] open failed: ' + JSON.stringify(error))
    })
  }

  @Builder
  Content(): void {
    Column({ space: 14 }) {
      Text('新建文件夹').fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary')).width('100%')
      Column({ space: 2 }) {
        TextInput({ placeholder: '输入文件夹名称', text: this.name })
          .height(40).fontSize(16).fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent)
          .border({ width: 0, color: Color.Transparent, radius: 0 })
          .padding({ left: 14, right: 14 }).enabled(!this.busy)
          .onChange((value: string) => { this.name = value })
          .id('create-folder-name')
        ContentDivider({ startInset: 14, endInset: 14 })
      }
      Row({ space: 8 }) {
        Button('取消').layoutWeight(1).height(42).fontSize(15)
          .fontColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent)
          .stateEffect(false).enabled(!this.busy)
          .onClick(() => this.onClose()).id('create-folder-cancel')
        Button(this.busy ? '处理中…' : '确定').layoutWeight(1).height(42).fontSize(15)
          .fontColor('#2E6BFF').backgroundColor(Color.Transparent)
          .stateEffect(false).enabled(!this.busy)
          .onClick(() => this.onConfirm()).id('create-folder-confirm')
      }.width('100%')
    }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 12 })
      .borderRadius(24).backgroundColor(Color.Transparent).id('create-folder-content')
  }

  build() {
    Column() {}.width(0).height(0)
  }
}

# 开发与构建

[返回项目首页](../README.md) · [使用说明](USER_GUIDE.md) · [文档目录](README.md)

## 环境与版本

| 项目 | 当前配置 |
| --- | --- |
| 语言与 UI | ArkTS / ArkUI，Stage 模型 |
| SDK | HarmonyOS API 26；最低兼容与目标均为 `26.0.0` |
| 工程模型 | Hvigor / OHPM，`modelVersion: 26.0.0` |
| 设备类型 | `phone`、`tablet`、`2in1` |
| 应用版本 | 以 [`AppScope/app.json5`](../AppScope/app.json5) 的 `versionName`、`versionCode` 为准 |
| 主模块 | `entry` |

使用能够安装 API 26 SDK 的 DevEco Studio。建议采用与工程对应的 26.0.0 Release 工具链；提交应用市场的包还需检查 SDK 的 `releaseType` 为 `Release`。API 23、24 尚未做兼容适配，不能仅下调 `compatibleSdkVersion` 就视为支持。

宿主机回归使用 Node.js 与 TypeScript；相册回归依赖 `node:sqlite`，建议使用 **Node.js 24 LTS**。ArkTS 应用本身仍由 DevEco 工具链编译。

## 首次准备

```powershell
git clone git@github.com:fhf2022/lvlian-view-hm.git
Set-Location lvlian-view-hm
Copy-Item build-profile.example.json5 build-profile.json5
```

也可使用仓库的 HTTPS 克隆地址。工程目录尽量使用不含空格的路径，随后在 DevEco Studio 中打开工程根目录。

1. 安装 API 26 SDK，在 IDE 中同步并安装 OHPM 依赖。使用命令行时，从工程根目录执行 `ohpm install`；命令不在 PATH 中时使用 IDE 内置的 OHPM。
2. 打开工程签名配置，用自己的开发者账号生成或选择证书、Profile 和私钥文件，填写本地 `build-profile.json5`。示例中的占位符不能直接用于签名。
3. 连接真机并确保设备包含在调试 Profile 中；模拟器能验证的系统组件、分享和媒体能力与真机不完全一致。

`build-profile.json5`、`local.properties`、`signing/`、构建产物及临时文件已忽略。不要把签名材料或凭据写入已跟踪的示例配置。

### 图库权限与开屏隐私

整相册读取使用 `ohos.permission.READ_IMAGEVIDEO`。除模块清单和系统运行时授权外，签名 Profile 还需要包含该受限权限的相应授权；普通文件选择器不能代替整个相册的读取权限。

当前后续开发中的开屏流程使用 AGC 托管隐私声明。自行构建时，应为自己的应用标识配置对应的 AGC 协议与完整模式隐私管理；只在项目中保存一份 Markdown 政策草稿，不能代替系统托管配置。如果停在开屏授权提示，先核对对应应用和 Profile 的隐私配置。

保留原应用安装数据的覆盖升级，需要沿用原有签名身份。自行签名的包通常不能覆盖其他证书签名的安装包，不要通过卸载用户现有应用来验证普通 UI 改动。

## 构建调试 HAP

可以直接使用 DevEco Studio 的构建与运行操作。以下是 Windows PowerShell 下已用于本工程的命令，安装位置不同时先调整 `$devecoStudio`：

```powershell
$devecoStudio = 'C:/Program Files/Huawei/DevEco Studio'
$env:DEVECO_SDK_HOME = "$devecoStudio/sdk"
& "$devecoStudio/tools/node/node.exe" `
  "$devecoStudio/tools/hvigor/bin/hvigorw.js" `
  --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

成功后，已签名模块包通常位于：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

签名未正确配置时构建会失败；不要把文件名包含 `signed` 视为验签通过的依据。

## 主机回归

在工程根目录运行。参数指向可用的 TypeScript 编译器；下面使用 DevEco 附带的路径，若安装布局不同请自行替换。

```powershell
$nodeRuntime = 'C:/Program Files/Huawei/DevEco Studio/tools/node/node.exe'
$typescriptRuntime = 'C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js'
& $nodeRuntime tests/upload-regression.cjs $typescriptRuntime
& $nodeRuntime tests/storage-regression.cjs $typescriptRuntime
& $nodeRuntime tests/album-upload-regression.cjs $typescriptRuntime
& $nodeRuntime tests/background-transfer-regression.cjs $typescriptRuntime
& $nodeRuntime tests/timeline-regression.cjs $typescriptRuntime
& $nodeRuntime tests/proximity-light-regression.cjs $typescriptRuntime
```

这些脚本执行生产逻辑并模拟系统服务、文件 IO 或 NAS 故障，适合检查队列、存储、分页、进度和取消竞争；不等同于真实 NAS、ArkUI 渲染或系统授权验证。ArkTS 单元用例位于 `entry/src/test`，设备测试位于 `entry/src/ohosTest`，可使用 IDE 测试入口执行。

传输与图库验证优先使用合成文件和独立测试目录。验证缩略图或 UI 时，不应顺带上传整个个人相册。

## 发布构建

公开示例只定义 `default` 产品。维护者本机可以额外配置名为 `release` 的产品，绑定正式发布签名；该本机配置不会提交到仓库。使用 `release` 产品前，必须先在本地产品配置和模块的 `applyToProducts` 中声明它。

```powershell
# 使用已配置产品；有独立 release 产品时可改成 'release'
$productName = 'default'
$devecoStudio = 'C:/Program Files/Huawei/DevEco Studio'
$env:DEVECO_SDK_HOME = "$devecoStudio/sdk"
& "$devecoStudio/tools/node/node.exe" `
  "$devecoStudio/tools/hvigor/bin/hvigorw.js" `
  --mode project -p "product=$productName" -p buildMode=release assembleApp --no-daemon
```

`buildMode=release` 决定构建模式，不会自动把调试证书换成发布证书；上架前必须确认所选产品绑定的是发布签名。APP 通常输出到 `build/outputs/<产品名>/`，上架产物还需要官方签名工具验证、版本检查和包内容核对。

如果另行交付可独立安装的 HAP，完成 APP 构建后，再运行对应产品的 `assembleHap` 并单独验签。`assembleApp` 过程中的内部模块包不一定能作为独立签名 HAP 分发。

发布及 AGC 权限政策核对见[上架历史笔记](AppGallery上架笔记.md)和[隐私政策填写清单](AGC隐私政策填写清单.md)。这些文件含历史版本记录，不能直接把早期状态表当作当前发布状态。

## 代码与文档维护

- 文件访问经过 `repository/` 与 `ugreen/`，网络故障由 `core/network/` 协调；新增页面不要自行再建一套网络探测和重试机制。
- 缩略图与原图使用不同的缓存、预加载及生命周期策略，先阅读 `media/` 相关模块，再调整加载与返回动画。
- 队列、后台保护和总进度分别位于 `upload/`、`download/`、`transfer/`，UI 应使用现有状态，不自行计算另一套总进度。
- 使用系统组件时先查官方文档，并与本机 SDK 声明核对。工程约定见 [`AGENTS.md`](../AGENTS.md)，可用 `devecocli docs search` / `docs read` 直接检索。
- 功能行为变化时同步更新使用说明。实验结论留在专题文档中，标明适用版本和验证范围。

提出修改时，请描述具体触发条件、改后行为与验证结果；反馈问题可使用仓库的 Issue 模板。

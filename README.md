<div align="center">
  <img src="entry/src/main/resources/base/media/icon.png" width="88" height="88" alt="联文件应用图标" />
  <h1>联文件</h1>
  <p>在 HarmonyOS 上浏览、整理和传输你的 NAS 文件。</p>
  <p>ArkTS · ArkUI · HarmonyOS API 26 · 手机 / 平板 / 2in1</p>
  <p>
    <a href="https://github.com/fhf2022/lvlian-view-hm/releases/latest">下载正式版</a> ·
    <a href="https://appgallery.huawei.com/link/invite-test-wap?taskId=a27ff0f8be31418852bb4465b727395f&amp;invitationCode=684SbeAJ8ao">加入邀请测试</a> ·
    <a href="docs/USER_GUIDE.md">使用说明</a> ·
    <a href="docs/DEVELOPMENT.md">开发与构建</a> ·
    <a href="docs/README.md">文档目录</a> ·
    <a href="https://github.com/fhf2022/lvlian-view-hm/issues">问题反馈</a>
  </p>
</div>

## 项目介绍

联文件是一个面向 HarmonyOS NEXT 的第三方 NAS 文件管理器，当前适配**绿联 NAS**。使用自己的云盘 ID 和 NAS 账号登录，即可访问个人目录与共享文件夹，浏览图片、播放音视频，并在设备与 NAS 之间上传、下载文件。

项目与 NAS 品牌方无隶属关系。当前工程的最低兼容与目标版本均为 **API 26**；尚未适配 API 23、24，也不适用于 Android 或旧版兼容 Android 应用的 HarmonyOS 环境。

## 主要功能

| 场景 | 支持的操作 |
| --- | --- |
| 文件管理 | 个人与共享目录、搜索、排序、新建文件夹、重命名、复制、移动、删除与回收站还原 |
| 图片浏览 | 列表、网格与瀑布流，日期时间轴，大图缩放、切换和拖动返回 |
| 批量选择 | 点击多选、长按拖选、靠近列表顶边或底边自动滚动 |
| 媒体播放 | 音频与视频播放、后台播放、视频画中画与系统投屏入口；具体能力取决于设备和媒体格式 |
| 上传与下载 | 独立任务队列、进度与速度、暂停和继续、断点恢复、系统传输进度通知 |
| 图库文件夹上传 | 系统相册选择，按创建任务时的图片清单批量上传，同名同大小跳过，名称冲突保留两份 |
| 缓存与离线 | 缩略图和原文件缓存、缓存上限、NAS 不可达时保留浏览位置与传输任务 |
| 系统交互 | 深浅主题、系统文件选择与分享、支持设备上的隔空传送 |

## 开始使用

1. 准备一台可访问的绿联 NAS，确认云盘 ID、NAS 账号及目录访问权限。
2. 在华为应用市场搜索「联文件」获取已上架版本，或从 [GitHub Releases](https://github.com/fhf2022/lvlian-view-hm/releases/latest) 获取正式签名包。自行构建请参考[开发说明](docs/DEVELOPMENT.md)；仓库源码可能领先于应用市场版本。
3. 首次打开完成隐私确认后登录。图库读取授权用于整相册上传；通知授权用于显示后台传输进度。

体验测试版本：点击[华为应用市场邀请测试](https://appgallery.huawei.com/link/invite-test-wap?taskId=a27ff0f8be31418852bb4465b727395f&invitationCode=684SbeAJ8ao)，按页面提示参与。

上传单个或多个文件：进入 NAS 目标文件夹，点击悬浮加号，选择文件或图片。

上传整个相册：进入 NAS 目标文件夹，点击 **悬浮加号 → 图库文件夹 → 选择相册 → 开始上传**。如果相册中包含云端照片，先在系统图库将原图缓存到本机，再回来刷新可上传数量。

详细步骤、权限说明和常见问题见[使用说明](docs/USER_GUIDE.md)。

## 使用边界

- **批量上传是一次清单上传。** 它不持续监控相册，不是双向同步，也不会删除手机或 NAS 中原有的图片；后续新增图片需要再次创建任务。
- **去重依据是文件信息。** 同名同大小跳过不等于内容哈希校验，不同名称的同一图片也可能再次上传。
- **云端照片需先缓存。** 系统相册显示的总数可能包含尚未下载的资源，可上传数量以本机实际可读取的图片为准；动态照片仅上传静态图片部分，视频不属于该批次。
- **后台传输需要系统保护。** 通知与相关通知渠道可用、后台保护申请成功时，切换应用或锁屏后可继续；保护不可用时转为前台传输。强制停止进程或重启设备后不保证自动执行。
- **离线浏览依赖已有缓存。** 未缓存的目录和原图仍需要连接 NAS；首次使用、所有 NAS 型号和所有媒体格式不承诺完全兼容。

## 开发导航

工程使用 ArkTS、ArkUI 和 Stage 模型，应用包名为 `cn.fhf.linkfiles`。版本以 [`AppScope/app.json5`](AppScope/app.json5) 为准。

```text
entry/src/main/ets/
├── pages/          主页面、文件浏览与查看器
├── components/     上传入口、传输任务行、相册与时间轴组件
├── repository/     NAS 文件仓库与目录元数据
├── ugreen/         绿联接口与业务错误处理
├── core/           网络、会话、加密与触觉反馈
├── media/          图片缓存、预加载、音视频播放
├── download/       下载队列、存储预算与文件保存
├── upload/         普通上传与相册批次、清单存储
└── transfer/       后台保护与总进度聚合
```

- [开发与构建](docs/DEVELOPMENT.md)：环境、签名、图库权限、构建命令和回归检查。
- [文档目录](docs/README.md)：功能设计、故障恢复和历史实验记录。
- [提交问题](https://github.com/fhf2022/lvlian-view-hm/issues/new/choose)：请注明应用版本、系统版本和复现步骤。

反馈截图或日志前，请遮住账号、云盘 ID、私人文件名和访问令牌。签名文件与本机配置不随源码分发。

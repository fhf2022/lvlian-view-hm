# 联文件传输实况窗接入依据与申请材料

日期：2026-10-10。应用：联文件；包名：`cn.fhf.linkfiles`；当前真机：HarmonyOS 7.0.0 / API 26。

## 2026-10-14 实况窗权益复查成功

12:02 使用本次重新构建的独立探针，在 `10.16.103.92:27677` 启动新进程。`isLiveViewEnabled()` 为 true；默认模板最简 `PROGRESS` 请求返回 `resultCode=0`，生产 `TransferLiveViewManager` 的进度模板也成功创建。当前 Push Token 与此前提交的 Token 一致。本次不再出现 `1003500005`，现有 Profile 已可使用，无需为了本次检查重新生成签名材料。

真机已看到通知中心的应用图标、42% / 8/20 进度、上传方向及进度环，锁屏区域也显示对应实况窗。探针只提供模拟进度，没有上传、下载、读取相册或写入 NAS。状态栏各类收起形态、亮暗主题及真实大批量后台传输尚未在本次完整验收，接口成功不替代这些 UI 与传输验证。

本次日志与结果位于 `temp/liveview-development/rights-recheck-20261014-redacted.log` 和 `rights-recheck-20261014-result.json`；原始日志与 Token 不加入 Git。设备自动锁屏后，按现有 `AUTO_STOP_WHEN_APP_TERMINATE` 生命周期结束探针进程，锁屏布局确认模拟卡片已移除；随后保留应用数据覆盖安装正常包。该模式经官方接口文档核对，无需为了恢复包再次解锁。

## 2026-10-13 调测名单提交后的第一次检查

用户已在 AGC 添加手机 Push Token。控制台截图显示添加时间 2026-10-13 11:59:19，状态“生效中”，有效期至 2027-01-11 11:59:19。12:01:59 使用 `temp/liveview-development/native-project/` 中的独立显示探针再次调用生产 `TransferLiveViewManager`，仍返回 `1003500005`；12:02:03 确认 active=false 并完成探针销毁。该探针仅提供固定 42% 的显示数据，没有上传、下载、读取相册或写入 NAS。

当前不能宣称展开卡片、收起胶囊及亮暗主题已通过真机验收。“生效中”不能单凭文案判定为尚未生效；之前要求等待变为“已生效”缺乏官方状态定义支持，已纠正。官方说明名单处理最长 24 小时，但当前 1003500005 的原因仍应核对 Token、应用身份、Profile 与设备端权限同步，不能直接归因于等待。日常 1.0.9 无探针包已恢复覆盖安装，保留应用数据。

## 2026-10-13 手动调试签名验证

13:32 新 Profile 对照：接入用户于 13:30:33 下载的最新调试 Profile。公钥、appIdentifier、设备绑定、READ_IMAGEVIDEO ACL 和 Live View/Push 服务能力与原 Profile 完全一致，解析后仅 uuid 变化。保留原 Profile 备份，生产及独立探针 HAP 均重新签名；通过官方 verify-app 抽出探针 HAP 的 Profile，验证与最新配置字节一致。真机覆盖安装成功，当前 Token 不变；最简请求和正常实现仍返回 1003500005，探针完成销毁。新 Profile 未解决该问题，不再把反复生成 Profile 当成后续方案。正常包已恢复；设备调测名单识别/同步与场景权益仍需平台侧确认。

13:24–13:30 权限链路复核：通过手机 `bm dump` 核对，安装的 appIdentifier 与手动调试 Profile、AGC 发布 Profile 一致；官方 hap-sign-tool verify-app 验签成功，抽出的 Profile 与配置文件字节一致。设备 API 为 26，PROGRESS/UPLOAD 符合当前 SDK 支持的场景。13:29:54 最简请求（默认模板、文本胶囊、32×32 应用图标，无进度环、尾图及新生命周期字段）与生产布局均返回 1003500005，失败不依赖自定义 UI。此前精简请求因漏填创建必需字段得到 401，已补齐，不能用该 401 推断业务问题。探针销毁后恢复正常包。

用户截图提醒调测前生成最新 Profile。目前文件生成于 10:23，早于 11:59 添加调测名单及数据位置调整。下一步建议同证书重新生成调试 Profile 做对照，目的为排除旧配置；尚未证实更新 Profile 必然解决。不要重建证书或卸载应用。

12:06 再次核对：用户确认默认数据处理位置已改为中国，重新通过 Push Kit 取得的当前 Token 与已提交名单的 Token 完全相同。全新进程调用仍返回 1003500005；原生层 PublishNotification 返回 67108900，未给出更具体的 Token/场景/同步原因。不能据此将控制台“生效中”解释为未生效，也未找到官方文档要求等待状态变成“已生效”。后续需继续定位设备端权益校验，等待同步只是一种可能。检查后已恢复无探针的正常使用包。

已接入用户下载的 `lianwenjian2.cer` 与 `shikuangchuangtestDebug.p7b`。证书叶节点公钥与原调试密钥、同密钥 CSR 一致；新 Profile 含 Live View、Push 服务能力和 READ_IMAGEVIDEO ACL。虽 App Identifier 与自动调试 Profile 不同，真机 `10.16.99.79:44631` 保留数据覆盖安装成功，没有卸载或生成新私钥。原证书/Profile 备份位于 `temp/liveview-development/manual-debug-backup/`。

新身份已成功获取 Push Token，保存在忽略版本控制的 `temp/liveview-development/PushToken.txt`，不写入源码。Live View 本地创建仍返回 `1003500005`；当前需要在 AGC 增长 → 推送服务 → 配置 → 联文件 → 实况窗调测设备管理中添加该 Token。官方说明名单在 24 小时内生效，暂未验证真实卡片、胶囊和亮暗主题。

独立探针完成合成 64 MiB 文件上传、下载与逐字节核对，清理完成。本轮 uploadBackground=false、downloadBackground=false，不能据此认定本轮后台验证通过。测试使用独立任务存储与 `/home/fhf/temp/liveview-test-*`，正常使用包不携带探针。下文签名未接通的说明为历史状态。

## 2026-10-12 接入与当前验证状态

1.0.9 已增加 `TransferLiveViewManager`，与既有 dataTransfer 保护分离，共用当前会话的字节加权进度。展示调用失败不影响后台保护和传输。创建仅在前台，更新合并且每秒最多一次；完成、中断、失败、取消、系统撤销保护及 Ability 销毁均处理收起。显式开始/继续允许重新尝试已恢复的实况窗权益，普通进度更新不重复请求未开通的权益。

新版设计保留前版 700 × 210 卡片比例；内部按同一垂直中心排版，去除上偏布局。实现沿用图片页的 `#2E6BFF` / `#AAB3C1` 进度环，通过 96 × 96 的辅助区图标显示进度与居中的方向／状态符号。2026-10-14 按真机反馈将胶囊左侧改为纯应用 Logo，取消包裹 Logo 的重复进度环；右侧尾图及展开卡片辅助区继续使用原进度环。Logo 缓存只解码一次，各次发布使用独立 PixelMap，避免上一帧回收影响缓存。常规、窄态及系统裁剪保留左 Logo 与可显示的右环，最小单图标形态显示 Logo；已知大小仅保留必要百分比，隐藏重复副文本，未知大小不伪造百分比。胶囊白底／暗色黑底随配置更新；卡片外框和基础区最终背景由系统模板控制，设计预览不能代替真机颜色、比例和收起方式的确认。

主机回归覆盖限频、主题切换、未知大小、部分／全部失败、完成／中断／取消、权益失败、迟到回调、部分区域失败与停止时的备用请求。原有上传、相册上传、存储和后台保护回归通过，Debug HAP 构建成功；正常 1.0.9 已保留数据覆盖安装，未携带探针。

真机合成 64 MiB 文件前台上传、后台下载及逐字节核对已完成，合成文件与目录已清理；本轮未验证真实相册的长期后台上传。新实验与日志存放 `temp/liveview-development/`，NAS 测试子目录位于 `/home/fhf/temp/`。常用真机地址在 `192.168.0.142:44631` 与 `10.16.97.39:44631` 间切换。

当前自动调试 Profile 的身份与 AGC 应用发布身份不同，缺少 `app-services-capabilities`；Live View 返回 `1003500005`，Push Token 返回 `1000900010`。CLI 重新生成前后均保留原密钥／证书／图库 ACL，仍未得到服务身份。用户新下载的 `t2Release.p7b` 含服务能力，与原发布密钥及 App Identifier 一致，已接入原发布配置并备份旧 Profile。它与手机当前调试密钥不同，不能据此宣称真机实况窗已开通或颜色已验证。

已从现有调试私钥在内存中生成 `temp/liveview-development/LinkFilesExistingDebugKey.csr`，验证 CSR 签名和公钥与当前调试证书一致；未重建密钥。下一步使用该密钥对应的调试证书与新的调试 Profile 完成真实应用身份验证，再按实际结果判断是否需要 Push Token 调测名单。添加调测名单是官方免除本地权限校验的调测途径，并非所有已获得正确 Profile 的本地创建都必须使用它。平台名单最多 24 小时生效。

下文保留 10 月 10 日的历史研究记录；“生产代码没有 Live View Kit”仅描述当时 1.0.8。

2026-10-13 最终 Debug／Release HAP 均构建通过；Debug 1.0.9 已覆盖安装并启动到 `192.168.0.142:44631`，保留数据，源码无探针。Debug HAP SHA256：`1721DBF4FCBE7065085F605CE83A469780BAF7BC9C8943FD98A31545E7A7DC69`。仍等待与现有调试密钥对应的、包含 AGC 服务身份的新调试 Profile；未以 Release 包替换手机的调试签名，也未卸载应用。

## 已有能力与缺口

1.0.8 的 `TransferBackgroundManager` 使用 Background Tasks Kit 的 `dataTransfer` 长时任务，并更新系统创建的同 ID 传输通知。通知授权修复后，真机可看到传输进度卡片。当前生产代码没有调用 `@kit.LiveViewKit`，也没有提供 `liveViewData.capsule`，不能据此宣称已经完成 Live View Kit 状态栏胶囊接入。

Notification Kit 的系统实况通知另有 `capsule` 可选字段，但显示效果依赖系统。需单独真机验证它是否允许 dataTransfer 类型显示胶囊，不能把 `publish` 返回成功当成胶囊显示成功。

2026-10-10 真机验证：应用通知总开关、LIVE_VIEW 通知渠道和 `liveViewManager.isLiveViewEnabled()` 均为 true。在实际合成文件上传中补齐 `clickAction`、进度模板、图标和进度胶囊后，`startLiveView` 返回 **1003500005：The right of liveView is not enabled**，证实当前应用缺少实况窗权益。另向同 ID 系统传输通知添加 `capsule` 和 `progress` 字段，`publish` 成功、后台上传成功，但桌面状态栏仍未出现胶囊。该系统通知字段方案不能作为本机已实现胶囊的结论。

诊断仅在独立验证项目中运行，合成 32 MiB 文件使用独立 NAS 测试目录和任务存储；测试结束清理合成源文件及任务，并将对应测试目录移入 NAS 回收站。正常使用包保留现有传输保护和通知，不包含 Live View 权益探针，不重复发起无权益调用。

官方当前已开放 `PROGRESS`（进度类型），适用用户手动开始的文件上传、下载。自动后台备份不在该场景范围内。本应用的“图片文件夹内图片上传”、文件上传和主动下载符合其描述；图片浏览缓存及缩略图预取不纳入。

## 官方开通路线

服务权益：AGC → 开发与服务 → 当前项目 / 联文件 → 项目设置 → 开放能力管理 → 实况窗服务 → 申请。提交场景描述和设计附件。审核通过后按官方流程重新生成 Profile，并保留原 `READ_IMAGEVIDEO` 图库权限及原证书。

调测：AGC → 增长 → 推送服务 → 配置 → 当前应用 → 实况窗 → 调测设备管理，使用设备 Push Token 添加。官方说明名单内设备不校验本地构建实况窗权限，生效可能需 24 小时。此调测途径需先开通 Push 服务并获取真实 Token；不能用设备 IP、UDID 或随意字符串代替。

正式上线：在调测设备完成卡片、胶囊、锁屏及异常状态验证，再申请实况窗正式权限。当前官方正式权限文档列出“已上架且月活 ≥ 1000”的申请条件；以 AGC 对当前应用实际开放的入口和审核结果为准。试用/调测效果不代表所有正式用户都能获得权益。

## 可填写的申请原因

精简填写版见 [LIVE_VIEW_APPLICATION.md](./LIVE_VIEW_APPLICATION.md)。

应用：联文件（cn.fhf.linkfiles）。

场景：PROGRESS，子场景 UPLOAD / DOWNLOAD。

用户手动上传手机相册图片至 NAS，或下载 NAS 文件。卡片使用应用图标和进度环展示整批进度，支持锁屏查看并点击返回传输页。覆盖传输、中断、完成、部分失败及取消；结束及时收起，不展示文件名或照片内容。

附件已生成：`artifacts/liveview-application-v2/联文件_实况窗申请附件_v2.zip`，含场景节点图、卡片/胶囊/锁屏方案图及申请说明。

图示为接入设计方案，非已上线效果截图。中断后结束胶囊、结果卡片保留 15 秒；完成或部分失败后结束胶囊、结果卡片保留 30 秒；用户取消立即结束。正式权限申请仍需联调后的真实效果截图。官方可视化工具可用于进一步对齐系统模板；本次图示不宣称为该工具导出或正式验收效果。

## 后续实现边界

卡片采用基础模板 `LAYOUT_TYPE_DEFAULT`，左上角为实际应用图标，右侧用 API 26 的 `ExtensionData.EXTENSION_TYPE_PROGRESS` 和 `progress` 展示总进度环；不采用 `ProgressLayout` 的横向进度条。完成显示 100%，中断保留最后进度，部分失败切换辅助区提示图标。胶囊采用 `CAPSULE_TYPE_PROGRESS`：`max=100`、`progress=总百分比`、`indeterminate=true`、`content=上传/下载/传输`，显示应用图标和百分比；卡片进度环字段不能用于胶囊。环的颜色和实际布局由系统模板决定。

继续由现有 dataTransfer 管理传输保活与系统取消事件。Live View Kit 是附加展示层：`startLiveView` / `updateLiveView` / `stopLiveView` 使用 `event: PROGRESS`，显式设置 `liveViewData.capsule`；共用现有 `TransferProgress` 汇总，不重新扫描相册。

前台且有实际任务时才能创建；本地更新依赖受保护的进程。使用 API 26 的进程结束自动终止生命周期模式，避免进程消失后留下“仍在上传”的胶囊。权益缺失、用户关闭实况窗或 Kit 调用失败时保留已有系统传输通知与保护，不能因此中断上传，也不能在应用内显示“实况窗已开启”。进度更新限频；暂停、完成、取消、NAS 离线和退出登录释放展示。

## 官方依据

- [Live View Kit 简介及开放场景](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-introduction)
- [构建本地实况窗](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-create-locally)
- [开通实况窗服务权益](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-rights)
- [接入联调测试](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-joint-commission-test)
- [申请正式权限](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-formal-authority)
- [实况窗设计规范](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-design-formula)
- [Live View Kit API：辅助区进度环与进度胶囊](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/liveview-liveviewmanager)
- [模板与应用图标规则](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-faq-4)
- [系统实况通知结构](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-inner-notification-notificationcontent)

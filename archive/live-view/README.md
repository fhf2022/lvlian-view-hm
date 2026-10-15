# 实况窗封存

2026-10-14：按用户要求停止自定义 Live View Kit 接入，等待以后具备正式场景权益再考虑恢复。此目录在 entry 模块之外，源文件不参与 HAP 编译，应用不会查询、创建、更新或结束自定义实况窗。

## 保存的内容

- `src/`：原实况窗管理器、卡片与胶囊展示模型、应用 logo 和进度环绘制。
- `integration/TransferBackgroundManager.with-live-view.ets`：封存时的接入参考快照。
- `tests/live-view-regression.cjs`：独立生命周期、权益失败、进度合并和资源释放回归。
- `docs/`：原开发、调测和申请记录。记录反映当时状态，不代表当前生产行为。

没有保存签名私钥、Profile、Push Token 或真机原始日志。这些本地材料继续按原忽略规则管理。

## 生产保留

`TransferBackgroundManager` 和 `TransferProgress` 保留当前会话总进度、通知首次授权、通知设置入口、系统 DATA_TRANSFER 保护、同 ID 进度更新和取消／恢复／销毁处理。API 字段 `SUBMODE_LIVE_VIEW_NOTIFICATION`、`NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW` 和 `SlotType.LIVE_VIEW` 是后台任务的系统传输通知，更新进度是 DATA_TRANSFER 的要求；它们不是这里封存的 `@kit.LiveViewKit` 自定义卡片／胶囊调用。

## 将来恢复

先确认正式场景权益、签名和上线设计符合当前官方规范，再将三个 src 文件放回 `entry/src/main/ets/transfer/`。对照 integration 快照恢复初始化、前后台／主题、进度更新、完成／取消、显式恢复和销毁钩子。不要直接覆盖当前 TransferBackgroundManager，避免丢失封存之后的维护修改。共享进度汇总仍使用生产 `TransferProgress`。

封存回归可在仓库根目录运行：

```
node archive/live-view/tests/live-view-regression.cjs <typescript.js>
```

后台保护回归仍使用 `tests/background-transfer-regression.cjs`，不再依赖任何自定义实况窗桩。

## 本次验证

生产 debug HAP 构建成功，字节码确认不含封存的管理器、绘图代码或 Live View Kit 创建／更新／结束调用。后台保护回归覆盖通知授权、渠道关闭、视频与传输任务隔离、发布失败、系统取消、恢复和更新节流；封存实现的独立回归也通过。

真机仅运行模拟进度：系统传输通知和总进度可见，退后台期间保护正常，点击通知进入应用，停止后通知移除。测试不访问 NAS 或相册。测试结束后覆盖安装正常 HAP，保留应用数据。构建、包审计和真机结果位于忽略版本控制的 `temp/liveview-archive/`。

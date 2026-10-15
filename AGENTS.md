# Codex 工程工具约定

本目录是 HarmonyOS 主工程。涉及 ArkTS、ArkUI、HarmonyOS API、DevEco 或官方开发指南时，优先使用已安装的 `devecocli` 查询官方文档：

```powershell
devecocli docs search "<关键词>" --catalog harmonyos-guides --format json --limit 10
devecocli docs read "<search 返回的 documentId>"
```

`devecocli` 位于 `D:\MyFilePath\NodeJS\node_global\devecocli.cmd`，与 `deveco` 使用同一 npm 全局前缀。`deveco` 的 `arkts_knowledge_search` 是模型驱动的内部 Agent 工具，不是本工程中可直接调用的命令；需要知识检索时使用上述 `devecocli docs` 路径。

详细说明见 [DEVECO_CODE_FOR_CODEX.md](./DEVECO_CODE_FOR_CODEX.md)。

## 真机连接

用户的无线调试端口通常为 `44631`，IP 通常在 `192.168.0.142` 与 `10.16.97.39` 之间切换。没有已连接目标时，先尝试这两个地址；两个都失败后再向用户确认，不要每次要求用户重复提供已知地址。

## 发布材料导出

用户指定的固定上架材料目录为 `C:/Users/admin/Desktop/联文件-上架材料/`。导出新版本时，不要只留在工程构建或 artifacts 目录；同步整理正式 `.app`、正式备用 `.hap`、更新说明、测试说明、包信息与 SHA256 校验到这个目录。沿用 `联文件-<版本>-三端-release` 的命名。正式 APP 与独立 HAP 分别验签，注意 assembleApp 中间产物不一定是可独立验签的 HAP。

根目录的旧发布包归入该目录下的 `历史版本/<版本>/`，校验目标路径和同名文件后再移动，保留已有图标、截图及调试材料。不得把私钥、签名密码或调试 Token 放进上架材料目录。

新增 user_grant 权限后，同步更新 `docs/AGC隐私政策填写清单.md` 与隐私政策权限用途；提醒用户在 AGC 托管政策的“设备权限调用”中添加对应结构化权限项，并确认待发布版本关联修改后的政策。文字说明不能代替平台权限项；1.0.9 的 `READ_IMAGEVIDEO` 用于用户选定相册的图片批量上传。

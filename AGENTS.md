# Codex 工程工具约定

本目录是 HarmonyOS 主工程。涉及 ArkTS、ArkUI、HarmonyOS API、DevEco 或官方开发指南时，优先使用已安装的 `devecocli` 查询官方文档：

```powershell
devecocli docs search "<关键词>" --catalog harmonyos-guides --format json --limit 10
devecocli docs read "<search 返回的 documentId>"
```

`devecocli` 位于 `D:\MyFilePath\NodeJS\node_global\devecocli.cmd`，与 `deveco` 使用同一 npm 全局前缀。`deveco` 的 `arkts_knowledge_search` 是模型驱动的内部 Agent 工具，不是本工程中可直接调用的命令；需要知识检索时使用上述 `devecocli docs` 路径。

详细说明见 [DEVECO_CODE_FOR_CODEX.md](./DEVECO_CODE_FOR_CODEX.md)。

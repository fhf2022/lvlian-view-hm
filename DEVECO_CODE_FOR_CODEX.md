# DevEco Code：给 Codex 的调用方式

版本：`deveco 0.1.7`

## 查询 HarmonyOS 官方文档

`arkts_knowledge_search` 不是独立的 `deveco search` 子命令，而是 DevEco
Agent 可调用的工具。调用链是：`deveco run` 启动 Agent → 选定 provider/model
生成一次模型请求 → 模型发起 `arkts_knowledge_search` → Agent 整理结果。
因此必须有可用的模型和认证；没有模型时没有 Agent 可以发起工具调用。

在 PowerShell 中执行：

```powershell
$deveco = "D:\MyFilePath\NodeJS\node_global\deveco.cmd"
& $deveco run --agent debug --model westlake/deepseek --format json `
  --dir "D:\code\harmony\lvlian view\ugreenlink-remote" `
  "请调用 arkts_knowledge_search 查询华为官方 HarmonyOS 文档：<问题或文档 URL>。只返回官方文档标题、链接和与问题直接相关的结论，不要修改工程文件。"
```

准备模型：

```powershell
deveco auth login                 # 仅 DevEco 托管模型需要（首次使用）
deveco providers list             # 查看 provider/认证
deveco models                     # 查看可用模型，格式为 provider/model
```

也可以在 `deveco run` 中用 `--model provider/model` 显式指定模型；模型不是
知识库本身，而是负责理解提示词、选择工具和输出结果的 Agent 推理服务。若使用
第三方 provider，则配置其 API key 即可，不必登录 DevEco 托管模型。

相关内置能力：

- `arkts_knowledge_search`：HarmonyOS 知识检索
- `webfetch`：抓取网页
- `websearch`：搜索网页

## DevEco CLI 直接检索路径

本机已将独立的 `@deveco/deveco-cli` 全局安装到与 `deveco-code` 相同的 npm 前缀：

```text
D:\MyFilePath\NodeJS\node_global\devecocli.cmd
```

涉及 ArkTS、ArkUI、HarmonyOS API 或官方开发指南时，Codex 应优先直接调用：

```powershell
devecocli docs search "<关键词>" --catalog harmonyos-guides --format json --limit 10
devecocli docs read "<docs search 返回的 documentId>"
```

这条路径不需要模型，返回的是随 CLI 打包的官方 HarmonyOS 文档索引和正文。
`devecocli serve mcp` 当前只提供 ArkTS/C++ 语法检查 MCP，不是知识检索接口。

## 检索异常时

华为文档页面是动态渲染的，可将官方地址加 `.md` 后交给 `webfetch`，例如：

```text
https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/image-overview.md
```

当前 `arkts_knowledge_search` 可能返回 `Unknown response format from knowledge service`；此时使用官方 `.md` 正文，并结合本机 SDK 的 `.d.ts` 交叉核对。

本机实测：若 DevEco Code 尚未完成 `deveco auth login` 或没有可用的模型/provider，
`deveco run` 可能长时间无输出而超时。这不是工程编译错误；应先配置 DevEco Code
的认证和模型，再重试知识检索。涉及 API 细节时，优先以开发者官网与当前 SDK
`.d.ts` 为准，CLI 检索结果只作为索引和补充。

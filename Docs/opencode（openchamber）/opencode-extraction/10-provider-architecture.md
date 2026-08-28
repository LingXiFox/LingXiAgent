# Provider Architecture

`Provider` 的输入是 models.dev catalog、config、auth、environment、plugins；输出是有 capabilities/limits/cost/options 的 Model 与懒加载的 AI SDK `LanguageModelV3`。

```text
agent/session model reference
  -> Provider.getModel(providerID, modelID)
  -> catalog + config merge -> Model
  -> Provider.getLanguage
  -> resolveSDK(model, provider state, env)
  -> bundled/dynamic AI SDK factory -> languageModel(api.id)
```

证据：`provider.ts:1074-1215` 定义 Model/Provider schema；`1261-1342` 将 models.dev 转为 runtime catalog；`1730-1921` 解析 SDK、baseURL/apiKey/headers/fetch timeout 并缓存 SDK/model。`Model` 的 `limit.context/output`、cost、reasoning、toolcall、modalities 和 interleaved 字段来自这一层。

认证来源优先级因 provider loader 而异；ProviderAuth 的 OAuth/API callback 将结果写入 Auth service（`provider/auth.ts:163-221`）。本报告不读取凭据值。

抽象并不完全干净：SDK factory 是通用边界，但 models.dev 的 npm/API 字段、bundled providers、provider-specific fetch、`ProviderTransform` 与 plugin auth 使厂商语义向上泄漏。详见 11。

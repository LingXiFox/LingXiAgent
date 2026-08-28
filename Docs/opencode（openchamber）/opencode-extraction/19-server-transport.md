# Server Transport

`opencode serve` 的 typed route composition 在 `server/routes/instance/httpapi/server.ts`：root/control、event SSE、PTY WebSocket、instance API、v2 server API、OpenAPI `/doc`、UI fallback 分层组合。

| 分类 | 例子 |
| --- | --- |
| transport-only | CORS/compression、OpenAPI、UI fallback、SSE encoding |
| runtime glue | auth、instance/workspace routing、Location context、service layer assembly |
| domain delegation | session prompt/abort/retry, MCP/provider/permission handler 调用 services |

HTTP endpoint handlers 依赖 service interfaces；route-layer instructions 明确“domain and storage services free of HttpApi types”。因此可概念拆 Core 与 HTTP。反面是 server 当前负责构建 `SessionV2` 和 local `SessionExecution` location map（299-303），所以替代 localhost HTTP 时仍必须提供等价的 request location、auth、lifecycle 和 service composition。

Server auth、directory scope、workspace routing 对 remote exposure 是真实安全边界；不能把 client SDK 看作 privileged direct Core access。

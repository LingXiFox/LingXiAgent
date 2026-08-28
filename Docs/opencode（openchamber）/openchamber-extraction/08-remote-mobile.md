# Remote 与 mobile

## Answer

官方 Mobile/Capacitor 客户端依赖 **OpenChamber API 为主，间接使用 OpenCode API**。它 talks to an OpenChamber runtime; that runtime proxies normal OpenCode `/api/*` calls and supplies product endpoints for auth, pairing, sessions activity, terminal, files, Git and notifications. Mobile does not connect straight to the OpenCode Server in the normal product path.

## Connection forms

| Form | Reachability | Authentication | Transport |
| --- | --- | --- | --- |
| Direct local/LAN/VPN/HTTPS | client has server URL | UI password session or remote bearer | HTTP/SSE/WS |
| Direct remote instance | Desktop saves another OpenChamber server URL | client bearer token created by pairing/connect link | HTTP/SSE/WS, optionally SSH forward |
| External tunnel | Cloudflare or ngrok maps a URL to server | same OpenChamber auth | provider tunnel plus HTTP/SSE/WS |
| Private Relay | host dials out, works through NAT | same bearer; relay does not authorize | E2EE multiplexed HTTP/SSE/WS over WebSocket |

## Pairing and client identity

`openchamber connect-url` and UI pairing create a v2 link:

```text
openchamber://connect?v=2&p=<base64url payload>
  payload: one-time pairing id + secret + transport candidates
```

The secret is a URL fragment credential in the normal pairing flow, is short-lived and stored hashed on the host. It is redeemed through `POST /api/client-auth/pairing/redeem` over the first reachable candidate. Successful redemption yields a trusted-device bearer `oc_client_...`; the host stores only its hash in `remote-clients.json`. The pairing link never embeds a reusable standalone client token. Evidence: `client-auth/pairing.js`, `client-auth/remote-clients.js`, `commands-connect-url.js`, `ui-auth/DOCUMENTATION.md`.

Password, passkey and pairing are credential *issuance methods*. Normal remote API requests use `Authorization: Bearer`; browser sessions use cookies. WebSocket upgrades cannot set headers, so the client first mints a short-lived URL-scoped token and sends it as a query parameter. Source: `relay/DOCUMENTATION.md`, `ui-auth/DOCUMENTATION.md`.

## Private Relay flow

```text
Mobile/PWA/Desktop client
  -> relay Worker websocket (routing ciphertext only)
  -> host's outbound relay connection
  -> ECDH + AEAD E2EE handshake
  -> tunnel multiplexing protocol
  -> host tunnel dispatcher
  -> loopback OpenChamber Server
  -> OpenCode proxy or OpenChamber product route
```

The host side is `packages/web/server/lib/relay/`; client code is `packages/ui/src/lib/relay/`; the broker is a separate Cloudflare Worker in the `openchamber-website` repository. The relay routes but cannot decrypt application payloads. Pairing candidates carry `relayUrl`, stable `serverId`, and host encryption public JWK, not a bearer token. `tunnel-host.js` decrypts then forwards only allowlisted HTTP and WebSocket paths to the host loopback server; it never adds credentials.

The client runtime transparently plugs this into `runtime-switch`, `runtime-fetch`, `runtime-url`, `runtime-socket` and `runtime-auth`. Application code should use those helpers instead of raw URLs/sockets. SSE is just a streamed HTTP response in this tunnel. Terminal and other real WebSockets are multiplexed as WS substreams.

## Reconnect and sync

- Upstream OpenCode SSE readers reconnect with `Last-Event-ID` on stall/close.
- Browser WS global bridge maintains a bounded event replay buffer; a recovered upstream emits a fresh `ready` signal so clients can repair state.
- UI stores scope stale work by runtime + directory + Session identity and perform authoritative refresh after reconnection.
- Relay reconnect makes a new E2EE channel; existing request retry/recovery handles it. A potentially delivered prompt is flagged as ambiguous and is refetched before retry to avoid duplicate Agent turns.
- paired clients can refresh candidates through `GET /api/client-auth/connection/candidates`; a server ID check prevents token disclosure to a new host at a reused LAN address.

Evidence: `event-stream/DOCUMENTATION.md`, `sync/DOCUMENTATION.md`, `relay/DOCUMENTATION.md`, `session-actions.ts`.

## Exposed endpoint/event categories

| Category | Examples | Auth |
| --- | --- | --- |
| OpenCode proxy | generic `/api/*`, message forwarder, provider OAuth callback, `/api/global/event`, `/api/event` | OpenChamber API guard then proxy |
| Runtime event WS | `/api/global/event/ws`, `/api/event/ws` | bearer or URL-scoped token |
| Auth/pairing | `/auth/*`, `/api/client-auth/pairing/*`, candidates | password/passkey/session/bearer as route requires |
| Server product APIs | settings, projects, goals, scheduled tasks, quotas, notifications, Git, FS, terminal | guarded OpenChamber API |
| Terminal WS | `/api/terminal/ws` | URL-scoped token |
| Synthetic event types | `openchamber:session-status`, activity, notification, heartbeat | delivered by server event bridge |
| OpenCode event payloads | Session/Message/Part/permission/question/etc. | forwarded from OpenCode SSE |

## Minimum remote replacement surface

To let a Web/PWA control a future core after Electron/OpenChamber removal, the minimum is: persistent host identity, one-time pairing, trusted-device credentials/revocation, server discovery/candidate refresh, authenticated HTTP request proxy/dispatch, resumable event stream, terminal WS if terminal remains, reconnect/state repair, and secure public reachability. Private Relay additionally needs E2EE handshake, multiplex framing and untrusted broker protocol. UI-only QR code without these host services is insufficient.

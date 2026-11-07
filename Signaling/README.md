# FarReach Cloudflare signaling

This Worker reconnects **already paired** FarReach Macs. First pairing still uses the private manual invitation/response exchange. The Worker exchanges presence, signed device agreement keys, and encrypted connection descriptions. Screens, input events, Mac passwords, and device private keys do not pass through it. Desktop transport remains direct UDP WebRTC; this service does not supply TURN or a media relay.


No hosted signaling endpoint is bundled. Deploy this service in your own Cloudflare account, then enter its HTTPS root URL in **Setup → Cloudflare signaling** on both Macs. Manual invitation/response pairing works without this service.

## Local development and deployment

```sh
cd Signaling
npm ci
npm run types
npm run check
npm test
npm run dev
```

The local endpoint is `http://127.0.0.1:8787`; FarReach allows unencrypted signaling only on loopback for development. Use an HTTPS Worker URL on both Macs for deployed service. Start cloud sharing on the host and use **Connect** for the saved Mac on the viewer. A Worker URL alone does not grant desktop access: both Macs must already trust each other's saved identity.

Deploy into the intended Cloudflare account using Wrangler OAuth:

```sh
npx wrangler login
npx wrangler whoami
npm run dry-run
npm run deploy
```

The deployment creates the `farreach-signaling` Worker, its SQLite-backed `DeviceMailbox` Durable Object namespace, and an upgrade rate limiter. No application API token or shared secret is embedded in FarReach or this repository. Wrangler credentials remain in Wrangler's local authentication store. Do not commit `.dev.vars`, `.env`, `.wrangler`, or credentials.

`GET /health` returns `{ "service": "farreach-signaling", "protocol": 1 }` without revealing connected devices. Use the HTTPS root URL (no `/v1/devices/…` suffix) in FarReach Setup. Account creation and plan changes are separate from deployment; these scripts do not purchase a plan or set a payment method.

## Privacy and operation

Cloudflare observes source IP addresses, stable hashed device IDs in WebSocket request paths, public keys, mutual peer allowlists, signaling timing, and encrypted envelope sizes. The Worker never intentionally logs message bodies, cryptographic signatures, or plaintext connection descriptions. Cloudflare's configured request logs may include request metadata. Its 10% observability sampling can be adjusted in `wrangler.jsonc`.

There is one authenticated socket per device. A replacement must prove the same identity using a fresh challenge before the old socket closes. Pending authentication expires after 10 seconds. WebSocket hibernation keeps idle presence connections without an application timer; literal `ping` / `pong` is handled by the platform. The current socket's ACL is stored in its Durable Object, then removed when that socket disconnects. Encrypted messages are forwarded immediately and never queued or persisted. Offline recipients require a new attempt.

Upgrade admission is limited to 60 requests/minute/IP at the edge before allocating a device object, plus 30/minute/device and three pending authentication sockets. Authenticated traffic is capped at 120 combined inbound/forwarded messages and 4 MiB per minute per socket. Payload strings are limited to 400 KiB of canonical base64url; allowlists contain at most 64 distinct peer IDs. These controls reduce abuse, but do not guarantee a spending ceiling or service availability. The endpoint permits other self-authenticated identities to register; an owner who needs a closed deployment should add an explicit enrollment policy before distributing its URL widely.

Signaling availability does not establish a working direct UDP path. Network filtering, incompatible NATs, offline Macs, sleep, logout, and FileVault pre-login remain separate limitations. A live authenticated desktop session does not require signaling to remain online. Keep the local manual connection mode as a fallback.

See [PROTOCOL.md](PROTOCOL.md) for exact wire details. The tests run in Cloudflare's actual local Worker runtime and cover authenticated forwarding, authorization/revocation, tamper and replay rejection, hibernation, connection replacement, input bounds, and timeouts. Native Swift integration and two-Mac WAN tests are separate checks.

Relevant platform references: [WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/), [Worker rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/), [current testing API](https://developers.cloudflare.com/workers/testing/vitest-integration/), and [Durable Object pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).

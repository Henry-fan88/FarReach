# Signaling protocol v1

Transport: native WebSocket at `wss://<worker>/v1/devices/<id>`. Production uses TLS; localhost development may use `ws`. Query strings and browser `Origin` headers are rejected. All protocol messages are JSON text with exact fields, except literal `ping` and its automatic `pong` reply. Unknown fields are rejected. Binary WebSocket messages are rejected.

All binary fields use canonical base64url without padding. Device `id` is the SHA-256 digest of its 32-byte Ed25519 public key (43 encoded characters). These signing identities are the same identities pinned during manual direct pairing.

## Register

Server sends a fresh random 32-byte nonce:

```json
{ "type": "challenge", "nonce": "<base64url32>" }
```

Client replies within 10 seconds:

```json
{
  "type": "authenticate",
  "publicKey": "<Ed25519 public key, 32 bytes>",
  "agreementKey": "<X25519 public key, 32 bytes>",
  "keySignature": "<Ed25519 signature, 64 bytes>",
  "signature": "<Ed25519 signature, 64 bytes>",
  "peers": ["<saved peer ID>"]
}
```

`keySignature` signs the concatenation of UTF-8 `FarReach-signaling-key-v1` plus one NUL byte and the raw agreement public key. `signature` signs UTF-8 `FarReach-signaling-auth-v1` plus one NUL byte, the raw nonce, then the raw agreement public key. The Worker validates both signatures, that the URL ID matches the signing key, and that the challenge has not been used. The nonce is consumed before asynchronous signature verification.

The Worker replies `{ "type": "ready", "capabilities": ["request-correlation-v1"] }`. Clients tolerate omitted capabilities from an older service. A newly authenticated socket replaces any older authenticated socket for the same identity (close code 4001). Invalid authentication never displaces an existing session.

`peers` contains at most 64 unique saved peer IDs, excluding self. Replace the list after pairing or Forget using `{ "type": "peers", "peers": [...] }`. There is no update acknowledgement; WebSocket message order is retained. Only mutually listed peers may discover or signal one another.

## Discover a saved peer

Client: `{ "type": "lookup", "to": "<peer ID>" }`.

When `request-correlation-v1` is advertised, clients may add `requestId`, a UUID string, to `lookup` and `signal`. The service echoes it unchanged on the associated `peer`, `sent`, or directed `error` response. It is not forwarded to the destination and grants no authority. Existing messages without this optional field retain their original response shape. Clients must ignore stale correlations instead of failing a newer attempt for the same device.

For an online, mutually authorized peer:

```json
{
  "type": "peer", "to": "<peer ID>", "online": true,
  "publicKey": "<peer Ed25519 public key>",
  "agreementKey": "<peer X25519 public key>",
  "keySignature": "<peer signature of agreementKey>"
}
```

Otherwise: `{ "type": "peer", "to": "<peer ID>", "online": false }`. If the requesting socket has not listed `to`, the response is `{ "type": "error", "code": "not-authorized", "to": "<peer ID>" }`. A peer that has not authorized the requester is indistinguishable from an offline peer.

The native client must verify the returned public key against its local saved identity and validate `keySignature` before encryption. The Worker is not an authority for granting new desktop trust.

## Forward an encrypted envelope

Sender:

```json
{ "type": "signal", "to": "<peer ID>", "payload": "<opaque AES-GCM data>" }
```

Recipient:

```json
{
  "type": "signal", "from": "<authenticated sender ID>",
  "payload": "<unchanged opaque AES-GCM data>",
  "publicKey": "<sender Ed25519 public key>",
  "agreementKey": "<sender X25519 public key>",
  "keySignature": "<sender signature of agreementKey>"
}
```

The sender cannot supply or override `from` or key metadata. The Worker checks both current allowlists. Success acknowledgement is `{ "type": "sent", "to": "<peer ID>" }`; this only confirms a WebSocket send, not acceptance or a direct connection. An unavailable or nonauthorizing destination produces error code `offline`. The Worker does not persist or retry payloads.

The payload is a canonical base64url string of at most 400 KiB and at least 28 decoded bytes (AES-GCM nonce plus authentication tag). Client cryptography, HKDF context, associated data, attempt IDs, message phase validation, expiry, and replay protection are defined by `Sources/RemoteCore/CloudSignaling.swift`. The server treats ciphertext as opaque. Native clients must validate the saved signing identity, authenticated encrypted envelope, intended recipient, attempt, expiry, and permitted state transition before acting. Direct WebRTC still performs its independent mutual identity handshake, pinned on both sides.

Current native clients negotiate v2 direct-transport invitations. Their encrypted message kinds also include `close`, `closed`, and `busy`. Close messages carry the authenticated connection's retained negotiation ID as `sessionID`, separately from their fresh request `attemptID`; a host only closes the matching current session of that same trusted peer. A busy response is retryable while a prior same-peer transport closes. Reject remains terminal, and neither a retry nor a close message enables sharing. These encrypted fields require no Worker payload inspection or storage.

## Failures and bounds

Errors use `{ "type": "error", "code": "...", "to": "..." }` with optional `to`. Codes include `invalid-message`, `authentication-failed`, `not-authenticated`, `not-authorized`, `offline`, `rate-limited`, and `internal-error`. Malformed messages, failed authentication, and traffic limit violations close the connection. Oversized/binary messages use close code 1009; policy failures use 1008. Retry only after correcting the cause or a bounded backoff; every reconnect authenticates a new challenge.

The maximum JSON message is 400 KiB + 1024 bytes. Edge connection admission, per-device pending/upgrade bounds, and per-socket traffic limits are specified in [README.md](README.md). Raw HTTP access cannot invoke internal Durable Object `lookup`/`relay` RPC methods.

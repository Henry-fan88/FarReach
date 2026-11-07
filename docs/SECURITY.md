# FarReach security model

FarReach is an early remote-control application, not an independently audited production access product. Its Internet transport, local transport, operating-system permissions, persistent identity, and connection setup have different trust boundaries. This document describes those boundaries; test evidence is listed separately in [ACCEPTANCE.md](ACCEPTANCE.md).

## Direct Internet pairing

The host creates an offer with a random 16-byte session identifier and 32-byte secret, generated using Go's `crypto/rand`. The `farreach-offer://v2/` value includes the WebRTC description, its DTLS certificate fingerprint, the secret, and a 30-minute pairing expiry. This is a bearer invitation, not a harmless connection address. Deliver it through a private, authenticated channel to the intended viewer.

The viewer returns a `farreach-answer://v2/` response. Its HMAC-SHA-256 binds the answer's version, session identifier, expiry, exact SDP, and a SHA-256 hash of the original offer SDP. The host validates that response against its retained offer before accepting the peer's connection description. The secret is not sent to STUN. WebRTC's DTLS layer supplies the peer transport encryption; HMAC authenticates the manual response rather than encrypting video itself. See [invitation implementation](../Networking/internal/invitation/invitation.go).

The offer is trusted because the user receives it from the intended host. There is no FarReach account identity, certificate-authority identity, or independent device directory. Someone who can replace the complete offer in the delivery channel can substitute another host. Someone possessing an authentic offer can prepare a valid response, so the host must return/paste responses only from its intended viewer. This is not multi-factor authentication.

Pairing expiry limits when an offer/answer can be used; it is not a statement that every established desktop session automatically ends after 30 minutes. Stop Sharing or quit to revoke the running session. Use End viewing to retain an already authenticated background link. After closing or losing that link, a new network exchange is necessary despite saved trust. Cloudflare signaling can carry that exchange for saved peers when cloud sharing is enabled; the manual path remains available.

Offers and responses also contain network candidates, which can expose local/public IP addresses. Do not include them in screenshots, public issue reports, logs, or source control. Copying them uses the system clipboard; clipboard-history and synchronization tools may retain copies beyond the app's control. Explicit memory zeroization is not implemented. Application cleanup cannot erase copies held by other applications.

## Persistent device identity and trust

FarReach uses a stable Ed25519 signing identity for each FarReach installation. Its device ID is derived from the public key; a display name is not an authentication factor. After the already authenticated manual transport is ready, the peers exchange fresh challenges and signed proofs before capture/control is admitted. The signed transcript includes both roles, both public keys/nonces, and a required 32-byte transport channel binding. A proof from another transport/session must not authenticate this connection. Selecting **Paired Macs → Connect** pins the expected device ID. See [DevicePairing.swift](../Sources/RemoteCore/DevicePairing.swift).

First pairing relies on the invitation/response being exchanged with the intended person/Mac. A fresh valid invitation authorizes establishing a new device relationship; stored identities are not an independent account directory or a second factor. A changed identity must not silently replace the saved expected peer.

`KeychainPairingStore` explicitly uses the classic macOS login Keychain for the private identity and saved device records. It does not opt into the data-protection Keychain or claim `AfterFirstUnlock`, `ThisDeviceOnly`, Secure Enclave protection, or availability under every lock state. Items are not configured for iCloud synchronization. A successfully loaded private identity is cached in RAM while the store lives; an explicitly locked Keychain can deny fresh reads or record updates. Such failure must be surfaced, not treated as successful persistent pairing. No Mac login password is stored.

**Forget** removes the selected record locally and closes a related live connection. It does not remotely erase the other Mac's Keychain record or create a global revocation list. **Stop Sharing** closes current host access and invalidates the active invitation. A new explicitly exchanged invitation can authorize pairing again; users revoking access should stop sharing on the host and remove records on both Macs if desired.

Saved trust survives an app restart only while its Keychain item remains accessible. The network transport does not: retaining a public key cannot recover an expired NAT mapping or reconstruct a stopped WebRTC session. Cloudflare signaling coordinates a new attempt with fresh transport parameters, and both peers verify the expected identity again.

## Cloudflare signaling for saved devices

The optional service uses a Cloudflare Worker and a Durable Object mailbox for each device identity. A native WSS client proves possession of its Ed25519 private key against a fresh server challenge. It advertises a signed key-agreement public key and the IDs of locally trusted peers. The service permits lookup and delivery only when both connected devices list each other. An authenticated mailbox is not permission to control the desktop: host sharing must be enabled and the local saved-peer check must pass.

The client derives a separate stable X25519 agreement key from its private device identity using domain-separated HKDF. A signature binds the advertised agreement key to the known Ed25519 identity. Signaling message bodies are encrypted with a peer-specific shared key using AES-GCM; authenticated data binds the direction and peer identities. The recipient checks the saved public key, key signature, message expiry and replay bounds before processing an attempt. The app additionally matches the expected attempt and protocol phase before applying an offer or answer. Both host and viewer pin the expected saved identity during the transport-bound pairing handshake.

This protects offer/answer contents, including their embedded pairing secrets, from the signaling service. It does not hide public identities, trusted-peer relationships, source IP addresses, online timing, or message sizes from Cloudflare. A malicious or unavailable service can delay or drop setup messages. The stable agreement key does not provide forward secrecy for previously recorded signaling ciphertext if the device private identity is later compromised. Device private keys and macOS passwords are never uploaded to the service.

The Worker bounds messages, connection attempts and delivery rates. Rate limits are not a billing-abuse guarantee: each deployment operator should monitor Cloudflare usage and review limits before wider exposure. No account email, Cloudflare API token or deployment credential is embedded in the app or source archive.

First pairing still relies on the private manual invitation/response channel. Cloudflare discovery cannot create trust with an unknown device. **Forget** updates the local allowlist and closes related access; the other Mac retains its own record until removed there. **Stop Sharing** disables host access even if its signaling client remains online. Opening the app, reconnecting WSS, or receiving a lookup does not automatically start capture. An established desktop session can continue if signaling becomes unavailable.

See [CloudSignaling.swift](../Sources/RemoteCore/CloudSignaling.swift), [the signaling service](../Signaling/README.md), and [network setup](NETWORKING.md).

## Direct means no configured desktop relay

Direct Internet uses STUN to discover socket addresses and ICE to test paths. The default public endpoint is `stun.cloudflare.com:3478` over UDP. Cloudflare receives discovery traffic and observes source addresses; it does not receive FarReach desktop/input payloads or pairing secrets. FarReach does not configure a TURN server. First pairing uses manual offer/answer exchange; later saved-peer exchanges can use the optional encrypted signaling service. [Cloudflare endpoint](https://developers.cloudflare.com/realtime/turn/), [STUN standard](https://www.rfc-editor.org/rfc/rfc8489.html).

Connection descriptions reject ICE relay candidates; configuration accepts at most three STUN-only URLs and rejects TURN URLs. Before reporting ready, the runtime checks that both selected candidates are allowed non-relay types and use UDP; it rechecks candidate-pair changes. It fails when a direct route is unavailable. It must not silently fall back to a TURN/media relay. This controls FarReach's selected transport; it cannot prove that an authorized peer, operating system, or network operator never forwards traffic elsewhere. Ordinary Internet routers/NATs necessarily remain in the packet path.

A managed network may block the needed UDP traffic or use NAT behavior incompatible with a direct session. The app must report this as a connection failure, not weaken authentication or encryption. A successful STUN response is not proof that the two peers can communicate. Public-IP discovery is not permission to alter a router or firewall, and Direct Internet does not make those changes.

## Bundled networking helper

The native app launches `Contents/Helpers/FarReachNetwork`, built from the original Go sources in [Networking](../Networking), with Pion WebRTC and other open-source dependencies. It runs as the same user and is part of the app's trusted code. It is not a privileged system daemon or a separately installed VPN. Configuration and frames travel over bounded binary standard-input/output pipes. The wrapper launches the helper without command-line arguments, supplies a minimal environment, and discards helper stderr rather than exposing secrets in logs. A closed or stalled helper can be terminated by the owning app transport.

Replacing the helper or the app's source can change the security properties. Local builds default to ad-hoc signing; published release notes identify Developer ID signing and notarization status. Source availability, code signing, notarization, and checksums are not an independent security audit. Dependency licenses are retained with the distribution.

## Local network mode

The `remotemac://host:port?key=…` invitation and original Network.framework transport remain for local/reachable private networks. They use a fresh 32-byte random key, TLS 1.2, and `TLS_PSK_WITH_AES_128_GCM_SHA256`, with negotiated-version/cipher checks and no plaintext fallback. See [Protocol.swift](../Sources/RemoteCore/Protocol.swift) and [Transport.swift](../Sources/RemoteCore/Transport.swift).

That legacy PSK cipher does **not** provide forward secrecy: later disclosure of the session key may expose recorded TLS traffic. Do not forward its default TCP port 9877 publicly as an Internet-mode workaround. The listener accepts on available interfaces, rather than being restricted to a particular Wi-Fi interface. Keep the key private and close sharing when no longer needed.

## macOS access and session lifetime

Screen Recording permits capture of the host desktop; Accessibility permits synthetic mouse/keyboard input. An authenticated controller can interact with the logged-in user's applications and data. FarReach does not create a restricted remote account or hide sensitive windows from the controller.

### Viewer shortcut capture

The viewer's **Full keyboard control** option uses a filtering Quartz event tap to receive keyboard combinations such as Command–Tab before the local system handles them. It requires local Accessibility access on the viewer as well as the host's existing permission for input injection. The app reports unavailable capture rather than claiming that typing alone proves system-shortcut support.

Forwarding and local suppression are scoped to the active, key FarReach window with the remote display as first responder, input enabled, and a current displayed frame. Invitation fields, other app windows, an unfocused remote surface, paused viewing, and unavailable screen states do not authorize shortcut forwarding. Losing that scope stops capture and releases held remote input. **Control–Option–Escape** releases focus locally and **Shift–Command–.** ends viewing locally; these escape actions are not sent to the host.

FarReach marks the events it injects so a local diagnostic or a returned synthetic event is not captured and forwarded again. This marker prevents feedback loops; it is not an authentication boundary. Remote authorization still comes from the authenticated transport, pinned device identity, explicitly enabled sharing, and host input checks. No key-content logging or clipboard synchronization is introduced by shortcut capture. Screenshot shortcuts invoke the remote operating system's own screenshot tools and save according to that Mac's settings.

### Host access and session controls

The host explicitly begins sharing. Capture/control must not start before transport and device authentication finish. **End viewing** requests capture pause and held-input release while retaining the authenticated transport/heartbeat. **Resume** uses that live connection. **Connect** establishes a fresh direct connection using signaling when available. **Close the background connection** and **Stop Sharing** end transport access; stopping sharing also revokes the current invitation. Closing a window does not quit the menu-bar app.

**Open FarReach when I log in** registers the main app through Apple's user-visible login-item service. It is not a hidden boot daemon, pre-login capture service, or promise to restore a lost connection. Rebuilding/moving an ad-hoc signed app may require refreshing privacy permissions and Keychain access.

The host's idle-system-sleep assertion permits display sleep and normal password locking, while trying to keep the running Mac reachable. It does not guarantee operation after explicit sleep, lid close, low battery, logout or reboot. **Wake Display** uses a bounded remote-user-activity assertion; it does not remove the password requirement. The app respects TCC and FileVault and never changes authentication policy to obtain access. If Accessibility is revoked, macOS can block synthetic release events as well as new input; cleanup cannot override that OS decision.

Normal macOS password-lock capture/input is a runtime compatibility question for the target OS/build. Do not infer it from ordinary desktop control, a screen saver test, or Apple Screen Sharing. The owner should type a password only into the visible current remote lock screen; FarReach has no login-password store, autofill form, or signaling path for passwords. A successful lock-screen image probe still does not establish successful remote password input. [Lock-screen evidence and test scope](LOCK-SCREEN-SUPPORT.md).

Input validation rejects nonfinite/out-of-range coordinates, unsupported buttons, key codes above 127, oversized scroll deltas, and unsupported modifier bits before CoreGraphics posting. Losing viewer focus requests release of held input. This is full-desktop control with validation, not a restricted command language. See [RemoteInput.swift](../Sources/RemoteMedia/RemoteInput.swift).

## Bounds and failure handling

Manual descriptions have a 128 KiB SDP limit and a 192 KiB encoded-envelope limit. The parser rejects unknown JSON fields, noncanonical base64url tokens, trailing data, expired offers, mismatched sessions and incorrect answer MACs. These checks limit accepted data; they do not establish parser or network denial-of-service resistance.

The binary framing layer bounds video to 16 MiB, hello/input/pairing/session-control/stream-state messages to 4 KiB, ping/pong/keyframe requests to 32 bytes, and disconnect text to 512 bytes. Helper configuration/events have separate 256 KiB IPC limits and must not be accepted as remote control messages. See [wire framing](../Networking/internal/wire/wire.go).

Internet video uses RTP/SRTP with bounded pacing and repair. Receiver storage is capped at 12 access units and 8 MiB. Recovery keyframes have a bounded two-second window, while delta repair uses RTT-dependent deadlines. Local app/helper media is chunked into 16 KiB pieces so control can interleave with video. Missing references require a keyframe before dependent video resumes. See the [transport design](../Networking/README.md) for current bounds; these do not guarantee a latency ceiling.

Capture availability is carried separately from video. Blank, suspended and stopped capture invalidate the cached image and old encoder pipeline. Frames carry an `FRS1` generation envelope around the H.264 payload; the receiver only displays the currently announced available generation. This prevents delayed pre-pause/pre-blank frames from reappearing after capture transitions. The viewer clears its image and ordinary input is gated while no fresh screen is available. Explicit authenticated Wake Display remains separate from normal input. These rules describe intended stale-frame protection, not a guarantee that ScreenCaptureKit can render every protected macOS surface.

The legacy LAN listener additionally caps pending handshakes at four, admits one authenticated viewer, sets handshake/partial-message deadlines, and bounds queued control traffic. These protections do not impose a strict ceiling on all OS, codec or WebRTC library allocations.

## Validation still required before relying on remote access

- Verify offer/answer tamper and wrong-session rejection, including a modified DTLS fingerprint and relay candidate.
- Confirm persistent identity proofs reject wrong keys, altered transcript/channel binding, replay and wrong role.
- Verify Keychain persistence/access-denial behavior without claiming stronger accessibility classes.
- Confirm End viewing releases input/stops capture while Resume reuses only the authenticated live link.
- Confirm Stop Sharing, failed pairing, helper exit, network loss, Forget and quit terminate the appropriate access.
- Verify Command–Tab hold/release and Command–Shift–4/5 affect the remote Mac while capture is focused, and remain local after focus release, pause, toggle-off or application deactivation. Check that held keys do not remain down after either escape action and that injected events are not forwarded twice.
- Exercise real video/control on two physical Macs over the intended networks, including a route where direct traversal fails.
- Confirm all interface labels distinguish an established direct path from signaling readiness, candidate gathering or a STUN success.
- Verify signaling challenge authentication, mutual allowlists, encrypted-message tampering, expiry/replay rejection, expected-peer pinning, cancellation, and lost-path reconnect.
- Test signaling reachability and direct UDP from the intended networks; neither is implied by a local test.
- Test stale/expired exchanges, reordered/lost video, capture epoch changes, stalled pipes, and resource exhaustion.
- Test screen saver, already-locked reconnect, display wake, and owner-entered password input separately; never silently weaken lock policy.
- Audit dependency updates, local secrets, logs, and distribution signing before wider use.

These items are acceptance/review requirements, not claims that every case has passed. No WAN latency or security-audit claim follows from a successful local test.

## Software updates

Configured releases use Sparkle with an HTTPS appcast URL and a pinned Ed25519 public key. The app requires a signed feed and validates the update archive before extraction. Public feed/key configuration is separate from the desktop-signaling URL. A build with no feed/key does not start the updater; partial or invalid configuration is rejected.

Private update-signing keys belong in the maintainer's Keychain or an external secret store. They are never bundled or committed. A compromised release-host account without the signing key must not authorize a modified archive. Protect and back up the signing key; key rotation and recovery require a planned release process.

Automatic installation is deferred while sharing, viewing, a paused connection, connection recovery, or local diagnostics are active. Restart preserves local trust/settings but does not restore host-sharing authorization. System profiling is disabled; update hosting still observes normal request metadata. Ad-hoc code signing is intended for development and does not replace Developer ID signing, notarization, or real old-to-new installation validation. See [release publishing](UPDATES.md).

## Reporting issues

Do not publish invitations, responses, passwords, private addresses, or captured desktop content. Use the repository host’s private vulnerability reporting channel when it is available. No public security contact is configured in this source distribution.

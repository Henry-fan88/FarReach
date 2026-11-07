# Validation and release checks

FarReach 0.5.1 is an experimental development release. Automated tests exercise synthetic content, local processes, and controlled network conditions; they do not establish reliable access through every pair of real networks.

## Automated coverage

- Swift: protocol bounds, persistent identity abstractions, pairing proofs, encrypted signaling, session lifecycle, input routing, native encode/decode, adaptive media, backpressure, and continuous synthetic video.
- Go: invitation authentication, direct-only ICE policy, framing, RTP recovery, pacing, queue bounds, helper lifecycle, and race-detector coverage.
- Worker: challenge authentication, mutual peer authorization, encrypted forwarding, replay/tamper bounds, socket replacement, hibernation, and attempt correlation.
- Packaging: both macOS architectures, app/helper signatures, third-party notices, archive integrity, and blank bundled signaling configuration.
- Updates: complete HTTPS/public-key configuration, deferred restart during active or paused sessions, preservation of framework symlinks/permissions, real signed-feed/archive generation, and rejection after tampering using disposable test keys.

Run the commands in the [README](../README.md#development-and-validation). Tests requiring a signaling URL, real Keychain access, or an extended encoder experiment are opt-in; skipped cases are not successful live tests. Use an isolated local Worker for signaling regression.

## Two-Mac acceptance

Before depending on a release, test the intended machines and networks:

1. Pair through a private invitation/response exchange, then reconnect through your own signaling service.
2. Confirm a fresh image and ordinary mouse, scrolling, typing, drag, and key-release behavior.
3. Verify focused Command–Tab and Command–Shift–4/5 affect the remote Mac; verify both local escape shortcuts release control.
4. Exercise End viewing/Resume, immediate Close/Connect, and a brief network interruption while viewing and while paused.
5. Confirm Stop Sharing, Forget, quit, and host restart do not silently restore access.
6. Try scrolling text and moving video under the expected network load; export diagnostics when a stall occurs.
7. Test display sleep, screen saver, password lock, and already-locked reconnect separately. Password entry is an operator action and must not be recorded in artifacts.
8. Confirm a network that prevents direct UDP produces a clear failure rather than a relay fallback.
9. Before publishing the first configured updater release, test an actual old-to-new in-place installation with a dedicated app: verify the update signature, persistent pairing/settings, and deferred restart. An unset release URL is not evidence of successful hosted update delivery.

Record software versions, hardware/OS, workload, duration, network type, and VPN/proxy state privately. Do not publish invitations, device identities, addresses, passwords, or captured desktop content.

## Measurement limits

FPS counts frames admitted to the display layer, not physical scanout. A static desktop can legitimately report zero FPS. RTT is round-trip transport/application delay, not glass-to-glass latency. Packet-gap counters can include reordering. Synthetic loopback and virtual-network benchmarks do not validate real-WAN responsiveness or remote password entry.

See [performance methodology](CONNECTION-PERFORMANCE.md) and [lock-screen test scope](LOCK-SCREEN-SUPPORT.md).

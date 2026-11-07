# FarReach

An open-source Mac-to-Mac remote desktop app for macOS 14 and later. Share your main display, control a trusted Mac, and return to an authenticated session without a desktop relay.

**Version 0.6.0 · experimental development build · MIT license**

FarReach uses direct connections. If the two networks cannot establish a direct UDP path, internet mode cannot connect. There is no TURN relay fallback or guarantee of access through every firewall or NAT.

## What it does

- Native screen capture and hardware-preferred H.264 encoding.
- Mouse, scrolling, keyboard input, and focused forwarding of Mac shortcuts.
- Persistent device identities and saved pairing in the macOS login Keychain.
- Pause/resume, display wake requests, and bounded automatic recovery after interruption.
- Adaptive video quality and local diagnostic exports.
- Signed in-app updates that replace the installed app, once a release feed is configured.
- Universal macOS application for Apple silicon and Intel, with its network helper included.

Audio, clipboard sync, file transfer, multi-display selection, FileVault/pre-login access, and guaranteed locked-screen control are not implemented or verified. The universal package contains both architectures; an architecture in the package is not a claim of runtime validation on every Mac or supported macOS version.

## Install

1. Extract `FarReach-macOS.zip`, or [build from source](#build-from-source).
2. Copy `FarReach.app` to `/Applications` on both Macs. Use the same release on both ends.
3. Open FarReach and visit **Setup**. The sharing Mac needs **Screen Recording** permission; remote input also needs **Accessibility** permission.
4. For system-shortcut forwarding, grant **Accessibility** to FarReach on the viewing Mac too.

The included development build is ad-hoc signed and is not Apple-notarized. macOS may require **System Settings → Privacy & Security → Open Anyway** after transfer. Quit the app before replacing it. A new development signature can require reviewing FarReach’s existing privacy permissions or Keychain access.

## Pair two Macs

1. On the Mac to control, choose **Share this Mac → Direct Internet → Create invitation**.
2. Privately transfer the invitation to the viewing Mac.
3. On the viewer, choose **Connect to Mac**, paste the invitation, and select **Connect**.
4. Copy the response back to the sharing Mac. Paste it into **Paste the other Mac’s response** and select **Finish pairing**.
5. After the encrypted connection and device identity checks succeed, both Macs appear under **Paired Macs**. Click inside the remote display to control it.

Keep invitations and responses private: they contain connection details and pairing secrets. A display name is not a device identity.

For two Macs on a reachable local network, **Local network** uses the TLS/TCP transport and does not need STUN or Cloudflare signaling.

## Reconnect using your own signaling service

**No hosted signaling URL or deployment credentials are included.** On a fresh installation the signaling field is empty, and manual invitation/response setup remains available.

To use **Paired Macs → Connect** after closing a connection:

1. Deploy the included [Cloudflare signaling service](Signaling/README.md) into your own account.
2. Enter the same HTTPS service URL under **Setup → Cloudflare signaling** on both Macs and select **Save**.
3. Complete the manual pairing above if the Macs are not already paired.
4. End the initial manual sharing session. On the host, select **Share this Mac → Direct Internet → Be available to paired Macs**.
5. On the viewer, select **Paired Macs → Connect**.

The service carries encrypted connection setup messages. Screen frames, keyboard events, and Mac passwords travel only on the direct desktop connection. Cloudflare can observe connection metadata, including IP addresses, device public identities, peer relationships, timing, and message sizes. Hosting is subject to your Cloudflare account’s usage and billing terms; consult its [current Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).

Both Macs must remain running and online. Sharing is an explicit choice: restarting FarReach does not enable sharing automatically. An upgrade preserves a signaling URL already saved on that Mac; the empty default does not clear existing settings.

## App updates

Configured releases check for signed updates and can download and install them automatically. Use **FarReach → Check for Updates…** or **Setup → App updates** to check manually and change preferences. Installation waits until sharing and remote connections have stopped, then replaces the existing app and restarts it. Pairing and settings are retained; sharing must be enabled again after restart.

This source snapshot has no update feed or signing key configured yet. Its update controls remain inactive until a configured release is installed. Version 0.5.1 and earlier need one manual upgrade to that first release. See [updater setup and release publishing](docs/UPDATES.md).

## Session controls

| Control | Behavior |
| --- | --- |
| **End viewing** or **Shift–Command–.** | Pauses capture and releases held input while retaining the background connection. |
| **Resume** | Returns to an open, authenticated connection. |
| **Control–Option–Escape** | Releases keyboard focus to the local Mac. Click the remote image to take focus again. |
| **Full keyboard control** | Forwards system shortcuts while the remote display has focus. |
| **Wake Display** | Requests display activity; it does not unlock the Mac or bypass its password. |
| **Close the background connection** | Ends the connection while preserving saved trust. |
| **Stop Sharing** | Ends host access and revokes the active invitation. |
| **Forget** | Removes the local saved peer and closes related access; it does not erase the other Mac’s record. |

Closing the main window leaves the menu-bar app running. **Open FarReach when I log in** starts the app at user login, not before FileVault unlock, and does not automatically start sharing.

Interrupted paired sessions retry for up to 60 seconds while the connection intent and host authorization remain active. Previously paused viewing remains paused. Explicit Close, Stop Sharing, Forget, and quit cancel the relevant recovery.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Cloud signaling is not configured | Deploy your service and enter its URL on both Macs, or use manual pairing. |
| Saved Mac is offline or unavailable | Confirm the other app is running, uses the same service, still trusts this Mac, and has sharing enabled. |
| Direct connection times out | Verify both networks permit direct UDP. Compare another network, such as a hotspot. Signaling or STUN success alone does not prove a usable desktop path. |
| Update required | Install the same release on both Macs. Version 0.4 invitations are incompatible with the version 2 internet protocol. |
| Screen appears but input fails | Check host Accessibility permission, viewer focus, and keyboard-capture permission. |
| Blank or locked display | Try Wake Display. Ordinary input stays disabled without a current image. Normal password-lock behavior needs validation on your Macs. |
| Slow video or repeated stalls | Start with Auto quality and export diagnostics. RTT measures a round trip, not input-to-visible latency. |

Only type a login password when the current remote lock screen is visibly available. FarReach does not store or autofill it. System sleep, lid closure, logout, reboot, and FileVault preboot are separate limitations.

## Build from source

Requirements: macOS with a Swift 5.10-compatible or newer Xcode/Command Line Tools toolchain, Go 1.25 or later, and Python 3. Node.js 24 and npm are used for signaling development. Dependencies are pinned in `Package.resolved`, `Networking/go.mod`, `Networking/go.sum`, and `Signaling/package-lock.json`. The initial Swift build downloads the pinned Sparkle binary framework.

```sh
./scripts/build-app.sh
python3 scripts/package-source.py
```

Outputs are `dist/FarReach.app`, `dist/FarReach-macOS.zip`, `dist/FarReach-source.zip`, and `dist/SHA256SUMS.txt`. The build script compiles both architectures, includes the helper and third-party notices, and ad-hoc signs by default. Set `FARREACH_SIGN_IDENTITY` to a suitable signing identity when preparing your own signed distribution; notarization is a separate step. Set `FARREACH_OUTPUT_DIR` to choose another output directory.

## Development and validation

```sh
./scripts/build-network.sh
(cd Networking && go test -race ./...)
swift test --disable-sandbox
python3 -m unittest discover -s Tests/PackagingTests -v
(cd Signaling && npm ci && npm run check && npm test)
```

The Swift suite uses synthetic pixels and non-posting input sinks. Some integration tests require a local signaling service and are skipped unless configured. Start `npm run dev -- --port 8787` in `Signaling`, then run:

```sh
FARREACH_SIGNALING_TEST_URL=http://127.0.0.1:8787 swift test --disable-sandbox
```

The real-Keychain and extended encoder tests remain opt-in. Live desktop capture/input and physical two-Mac behavior require separate checks. See [validation](docs/ACCEPTANCE.md), [network behavior](docs/NETWORKING.md), [performance](docs/CONNECTION-PERFORMANCE.md), and the [0.5.1 video fixes](docs/FPS-RECOVERY-FIX.md).

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/FarReach` | SwiftUI app, session lifecycle, and diagnostics. |
| `Sources/RemoteCore` | Pairing, identity, signaling, and transport integration. |
| `Sources/RemoteMedia` | Capture, H.264, presentation, and input. |
| `Networking` | Bundled Go/Pion direct UDP transport. |
| `Signaling` | Optional self-hosted Cloudflare Worker and Durable Objects. |
| `Tests` | Swift regression and integration tests. |
| `scripts` | Build, dependency notices, source packaging, and benchmarks. |
| `docs` | Security, networking, performance, and validation details. |

## Security and license

An authenticated controller has the logged-in user’s desktop privileges. FarReach is experimental and has not undergone an independent security audit. Read the [security model](docs/SECURITY.md) and [lock-screen limitations](docs/LOCK-SCREEN-SUPPORT.md) before relying on unattended access.

Original code is licensed under the [MIT License](LICENSE). Sparkle and its bundled third-party notices are included with the app. Bundled dependency licenses are retained under [Resources/ThirdParty](Resources/ThirdParty). No account credentials, saved device identities, personal diagnostics, or hosted signaling configuration are distributed.

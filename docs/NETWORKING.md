# Connecting and returning to a paired Mac

FarReach 0.5 separates **device trust**, **the network connection**, and **viewing the screen**. Trust can be saved in Keychain after the first authenticated exchange. The active connection can remain in the background when viewing ends. A saved trust record cannot discover a Mac's new address or recreate a vanished UDP path by itself.

Cloudflare signaling supplies discovery and a fresh connection exchange for already trusted devices. The existing direct connection can also stay alive while viewing is paused. Screen saver/display-off changes need not end that connection while the host app, user session and network remain running. Sharing must be enabled explicitly after the host app restarts.

## First Direct Internet connection

1. Put the same current FarReach build on both Macs. On the sharing Mac, grant Screen Recording and Accessibility; reopen if macOS asks. If macOS shows a Local Network/firewall prompt, permit FarReach only on networks you are authorized to use.
2. On the host, choose **Share this Mac → Direct Internet → Create invitation**.
3. Transfer the invitation privately to the viewer. On that Mac, choose **Connect to Mac**, paste it, and click **Connect**.
4. Choose **Copy response** and return it to the host. Paste it into **Paste the other Mac’s response** and choose **Finish pairing**.
5. Both apps verify the encrypted transport and prove their device identities. Successful device records appear in **Paired Macs**. A Keychain access/storage failure is reported rather than silently claiming that trust was saved.
6. Click the remote screen to control it. For remote system shortcuts, enable **Full keyboard control** and grant FarReach Accessibility access on the viewer too. Keep the host logged in, powered and connected.

Invitations and responses contain connection/security data and may expose local/public IP addresses. Keep them out of public chat, issue reports, screenshots and logs. A successful fresh invitation exchange authorizes a new pairing; do not share an invitation with someone you do not intend to authorize.

## Send keyboard shortcuts to the remote Mac

The host needs Accessibility to inject keyboard and mouse events. The viewer also needs Accessibility for **Full keyboard control**, which intercepts combinations that local macOS would otherwise handle before FarReach receives them. This is separate from the host's Screen Recording permission; a viewer still does not need permission to record its own display.

Enable **Full keyboard control**, then click the remote image. While that image has keyboard focus in the active FarReach window:

| Shortcut | Remote action |
| --- | --- |
| Command–Tab | Hold Command and press Tab to switch apps; releasing Command selects the app. |
| Command–Shift–4 | Start screenshot selection; drag on the remote image to choose the area. |
| Command–Shift–5 | Open the remote Screenshot controls. |
| Control–Option–Escape | Release keyboard focus locally; click the remote image to control it again. |
| Shift–Command–. | End viewing locally and retain the background connection. |

Screenshots belong to the remote Mac and use its configured save location. Keyboard layout and remote macOS shortcut settings still matter. OS-protected or hardware-only keys are not promised to work merely because ordinary app shortcuts do.

The toggle, focus, and capture status determine where shortcuts go. If capture is unavailable, check FarReach's permission guidance on the viewer; do not interpret successful ordinary typing as proof that system shortcuts are being intercepted. Capture stops when focus leaves the remote screen, the app/window becomes inactive, viewing ends, or the screen becomes unavailable. Held remote input is released during these transitions.

## Configure and use Cloudflare signaling

Deploy [the signaling Worker](../Signaling/README.md), then set the same HTTPS service URL in **Setup → Cloudflare signaling → Save** on both Macs. The app authenticates with its existing device identity; the Cloudflare account password or API token is not entered into FarReach. Complete the private first pairing above before using discovery.

On the host, close the manual sharing session and choose **Share this Mac → Direct Internet → Be available to paired Macs**. On the viewer, choose **Paired Macs → Connect**. The host accepts only a locally trusted device. A fresh, short-lived encrypted exchange carries the WebRTC offer/answer; both ends then pin the expected device identity during the direct transport handshake. The service does not stream desktop data.

The host stays available for a fresh request after a direct session ends while cloud sharing remains enabled. **Stop Sharing** disables that access. The viewer starts with **Connect**. A temporary interruption of an existing session triggers automatic recovery for up to 60 seconds, preserving active or paused viewing intent. Reconnecting signaling alone does not grant access or enable host sharing. A temporary signaling outage does not deliberately tear down an established desktop connection.

Both Macs must reach the service using HTTPS/WebSockets and establish direct UDP connectivity. Reachable signaling cannot overcome blocked UDP or incompatible NAT mappings. Test both intended networks, including Wi-Fi/hotspot changes. A custom hostname may be configured at Cloudflare, but it is not a guarantee of reachability.

Leave the signaling URL empty for manual setup only. A signaling URL saved in Setup does not automatically start host sharing.

## Returning without repeating the exchange

On the viewer, choose **End viewing** (also **Shift–Command–.**). The host pauses capture and releases held input; both apps keep the authenticated transport and heartbeat active. Do not choose **Close the background connection**, **Stop Sharing**, or quit either app if you want to reuse this live path.

Open **Paired Macs → Resume** on the viewer to return. Resume requests display activity and a new capture generation over the already authenticated channel. **Wake Display** is also available in the viewer, including when the last image has been cleared. A new valid frame is required before ordinary keyboard/mouse input is enabled.

These controls have different effects:

| Control/event | Connection | Saved device trust |
| --- | --- | --- |
| End viewing | Kept alive; capture/input pause | Kept |
| Resume | Uses the existing authenticated link | Reused |
| Close the background connection | Closed on the viewer | Kept |
| Stop Sharing | Host access closed; current invitation revoked | Kept |
| Forget | Removes the selected local record; related live connection is closed | Removed on this Mac only |
| Quit, logout, reboot, network failure | Existing path may be lost | Kept if Keychain remains available |

When **Paired Macs** says trust is saved but the connection is not open, use **Connect** with signaling ready and cloud sharing enabled on the host. If signaling is unavailable, **Set up connection** accepts a fresh private invitation. Both paths pin the expected device identity; a different Mac cannot substitute merely by using the same display name.

## Screen saver, display off and lock screen

The sharing app requests idle-system-sleep prevention while available. This allows display sleep and normal screen locking; it does not prevent lid-close, deliberate sleep, low-battery shutdown or every managed policy. The whole machine must remain reachable.

**Wake Display** reports remote user activity through a public IOKit API. It does not unlock macOS. Capture unavailability clears cached frames and the viewer's last image; resumed capture carries a new generation so delayed old frames are ignored.

For a normally locked user session, the owner should type the password only when the current remote lock screen is visible. FarReach does not save or autofill that password. Starting ScreenCaptureKit while already locked and delivering keys to the lock UI need live verification on the target OS/build. Logout, FileVault preboot, powered-off state and closed-lid sleep remain outside the supported guarantee. [Lock-screen research and test procedure](LOCK-SCREEN-SUPPORT.md).

The **Open FarReach when I log in** option uses Apple's login-item service. It can reopen the app when that user logs in. It is not a boot-time capture service and does not start sharing automatically. Enable cloud sharing on the host before leaving it available to trusted devices.

## What STUN does

The default service is `stun.cloudflare.com:3478` over UDP. It reports externally observed socket addresses; it does not carry the desktop stream, store the Mac login password, or deliver future peer updates. Cloudflare documents its public STUN service as free and unlimited. FarReach does not configure TURN. [Endpoint](https://developers.cloudflare.com/realtime/turn/), [FAQ](https://developers.cloudflare.com/realtime/turn/faq/).

A managed Wi-Fi network or hotspot may permit direct UDP hole punching, even with CGNAT. Conversely, blocked UDP, difficult mappings at both ends, or incompatible IP paths may prevent it. Seeing a STUN response is not proof that the two peers can communicate. [ICE standard](https://www.rfc-editor.org/rfc/rfc8445.html), [connection conditions](https://tailscale.com/docs/reference/connection-types).

FarReach accepts only STUN configuration and non-relay candidates, then verifies the selected path is non-relay UDP. If no direct path works, it fails. It does not alter the router, enable UPnP, create a port mapping, or weaken a firewall. The read-only **Check this network** feature can inspect local/address-discovery conditions but cannot establish reachability to the other Mac.

## Local network mode

Choose **Local network** on the host, select a reachable local address, start sharing, and copy the invitation. Paste it into **Connect to Mac** on the viewer. The direct TLS-PSK/TCP listener uses port 9877 by default; this transport contacts no STUN or signaling service. Persistent device authentication and End viewing/Resume also apply. A separately configured signaling client may remain connected, but this transport does not use it.

Private addresses generally work only within their LAN/overlay. Guest Wi-Fi/client isolation may block them. A DNS name does not create reachability. Do not publish the legacy LAN listener as an Internet-mode workaround.

## Installation and Keychain

Use one installed app copy. A rebuilt ad-hoc signature can require refreshing Screen Recording/Accessibility and separately approving Keychain access. If a privacy switch is on but the app still reports denied access, remove only FarReach's stale entry, add the current app, and reopen it. Do not disable system protection globally.

Device identity and trust use the classic macOS login Keychain. A successfully loaded identity stays cached in the running app, but a manually locked Keychain can deny fresh reads or record updates. This does not claim `AfterFirstUnlock`, `ThisDeviceOnly`, or data-protection Keychain semantics. No Mac login password is stored.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Cannot create invitation | Complete app/helper bundle, network, STUN settings, recording permission. |
| Waiting after viewer prepares response | Return the response to the running host and choose Finish pairing. |
| Identity or response rejected | Current unmodified exchange, selected expected Mac, current build on both ends. |
| Saved Mac has no Resume button | Use Connect when signaling is ready and the host is available to paired Macs; otherwise use Set up connection for a manual exchange. |
| Signaling does not become ready | Same valid HTTPS URL on both Macs, deployed Worker, reachable DNS/HTTPS/WebSockets, and access to the device identity in Keychain. |
| Paired Mac is unavailable | Both apps running, both records still trusted, host cloud sharing enabled, and signaling connected. |
| Resume shows no current screen | Host permission/session/display state; Wake Display / Retry; do not type a password into an unavailable image. |
| Screen is visible but control fails | Host Accessibility permission, active viewer focus, and actual lock-screen input support. |
| Typing works but Command–Tab or screenshot shortcuts act locally | Enable Full keyboard control, grant viewer Accessibility access, check the capture status, and click the remote screen. |
| Keychain operation fails | Unlock the login Keychain or review this app's access; do not reset global Keychain/security settings. |
| Route lost or app restarted | Use Connect again; after a host app restart, explicitly enable Be available to paired Macs. Direct UDP still needs to work. |
| High latency or stutter | Use Auto quality; export connection diagnostics to distinguish network feedback, encoding, and UI handoff delays. See the performance validation guide. |

The 0.5 candidate uses RTP/SRTP video with bounded congestion control and repair. Both Macs need the v2 internet protocol. See [performance changes and validation](CONNECTION-PERFORMANCE.md). No measured glass-to-glass WAN latency is established. RTT is application ping/pong, FPS counts admitted/enqueued frames, and Mbps excludes transport overhead. Use [ACCEPTANCE.md](ACCEPTANCE.md) for real-network validation.

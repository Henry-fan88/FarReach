# FarReach 0.5 connection performance

This version keeps direct UDP connectivity and the existing saved identities.
Both Macs must run 0.5: internet invitations and the helper protocol now use v2.
Version 0.4 invitations are incompatible; saved device identities remain valid.

## What changed

- Internet video uses H.264 RTP/SRTP. Reliable session/key/button/scroll messages
  remain on SCTP; replaceable pointer positions use a separate unordered channel.
- Pion TWCC/GCC supplies a bandwidth estimate. A bounded pacer budgets original
  packets and repairs together; NACK requests are limited to two per packet.
  Frame deadlines and byte limits prevent an accumulating video backlog.
- Capture generations and frame metadata accompany every RTP fragment. Helper
  authorization, receiver preparation, and UI presentation each reject obsolete
  generations. Pause, blank capture, and reconnect invalidate queued media.
- Auto starts at a 1280-pixel longest edge, 30 fps, 2 Mbps and can grow toward
  1920 pixels, 60 fps, with a 12 Mbps encoding ceiling. Presets remain ceilings.
  Bitrate responds before geometry; geometry changes require sustained feedback.
- Media serialization and native decoding run away from the main actor.
  Both helper output and Swift input preserve up to 12 compressed references /
  8 MiB. After decoding every reference, a mailbox retains only the latest pixel
  image for presentation, so UI stalls do not break the H.264 chain.
  Local helper media is chunked into at most 16 KiB pieces, allowing critical
  control messages between chunks. Pointer snapshots are coalesced on both ends.
- A temporary interruption has a short grace period followed by fresh,
  identity-pinned negotiation through configured signaling. A single recovery
  attempt runs at a time, with bounded backoff and a 60-second overall budget.
  Paused intent remains paused. Explicit Close, Stop Sharing, Forget, and shutdown
  cancel recovery. Session-scoped close and retryable busy responses resolve the
  previous immediate-reconnect race.

## Measurement semantics

The app's diagnostics export holds at most 1,800 periodic samples. It excludes
screen content, input contents, device names/identifiers, addresses, and secrets.

- Application RTT uses a monotonic ping/pong clock. Transport RTT comes from the
  selected path/SCTP. Neither is glass-to-glass or input-to-visible latency.
- Capture-to-encode duration subtracts timestamps from the same host clock.
  Cached static-image recovery retains the image's original capture time.
- Viewer decode/preparation and UI handoff are local intervals. Host monotonic time is
  never subtracted from a viewer clock without clock synchronization.
- FPS and enqueue gaps describe admission to the display layer, not physical
  scanout. A long gap on an unchanged desktop is not automatically a freeze.
- `packetsLost` means observed RTP sequence gaps, and `packetsRepaired` means late
  arrivals filling those gaps. Reordering can contribute to both. These are not
  physical link-loss percentages or confirmed retransmission counters.
- Sender-side receive counters are not remote receiver measurements. Auto uses
  GCC feedback, local queue pressure, and frame-drop pressure; a zero local
  receive counter is not presented as zero WAN loss.
- Encoding skips count admission attempts, including cached-image retries;
  they are not a captured-frame-loss percentage. Codec drops, transport drops,
  and UI admission remain distinct. Pipeline counters can reset when a capture
  generation is rebuilt. Summary percentiles describe retained periodic samples.

## Reproducible validation

Run the ordinary regression suites and build the helper before Swift integration:

```sh
./scripts/build-network.sh
(cd Networking && ../.tools/go/bin/go test -race ./...)
swift test --disable-sandbox
(cd Signaling && npm run check && npm test)
```

Set `FARREACH_SIGNALING_TEST_URL` to an isolated local Worker to include signaling
and recovery integration. `FARREACH_NETWORK_HELPER` can select a separate test
helper. Tests use in-memory identities, synthetic pixels and non-posting input
sinks; the real Keychain test remains opt-in. macOS sandbox restrictions can
prevent local sockets, process inspection, or synthetic pixel-buffer allocation.

For actual ICE/DTLS/SRTP/SCTP over Pion's virtual UDP network:

```sh
./scripts/test-network-performance.sh
FARREACH_NETWORK_LONG=1 ./scripts/test-network-performance.sh
```

The long mode runs 20 seconds per profile. The runner also checks a deliberately
lost first retransmission and a separate jitter/burst/15→2→15 Mbps case whose
offered rate exceeds the temporary bottleneck. Fixed profiles cover 20/80/150 ms configured
RTT, 0/1/3/5% injected media loss, and 2/5/15 Mbps bandwidth. The legacy comparator
reproduces the former zero-retry SCTP media algorithm only inside tests; it is not
a production fallback. Synthetic NAL payloads exercise transport/framing, not
native codec quality. Loss is injected into media-bearing datagrams, so these
figures are not a complete model of every real Wi-Fi or ISP failure.

`sendToIPC_p95` measures only successfully delivered synthetic frames. Assess it
alongside delivered-frame counts and gap measurements: a transport that loses
many frames can misleadingly show low survivor latency. These tests exclude
ScreenCaptureKit, native encode/decode, UI scheduling and display scanout.

## Recorded measurements (2026-11-05)

In an arm64 development test, the packaged helper's
720p native-codec synthetic input-to-decoded-response test passed all 20 measured
responses: p50 8.21 ms, p95 10.19 ms, max 10.38 ms. This is loopback, not physical
capture/display or WAN. Native burst tests separately decode complete IDR/P
reference chains while delaying UI consumption, then present only the latest
independent pixel image without requesting another keyframe.

A representative 20-second virtual-network comparison used 80 ms configured
RTT, 3% configured media loss, and 5 Mbps capacity:

| Measurement | RTP candidate | Previous algorithm |
| --- | ---: | ---: |
| Delivered synthetic frames | 524 / 600 | 315 / 600 |
| Gaps above 250 ms | 7 | 20 |
| Longest frame gap | 509 ms | 754 ms |
| Control RTT p95 | 82 ms | 95 ms |
| Aggregate frame-gap excess over 33 ms | 9.60 s | 10.28 s |
| Successfully delivered frame latency p95 | 234 ms | 63 ms |

The candidate repairs more frames, which also makes its survivor-only latency
higher. Long-gap count fell 65%, but aggregate gap excess fell only about 7%;
this is **not proof of the 50% freeze-time target**. These metrics are transport
proxies, not physical display freezes. Runs vary with scheduling and traffic.

In the combined jitter/burst/capacity-collapse stress test, control survived and
queues remained bounded, but video still stalled: the recorded helper-delivery
p95 was 352 ms and the longest frame gap was 605 ms. Smoothness under severe
combined stress needs further work. Below the native encoder's 500 kbps setting
floor, adaptation can also reach its minimum; no low-bandwidth guarantee is made.

## Release acceptance

The user-visible targets remain acceptance gates for the complete native path:
healthy 80 ms RTT/15 Mbps p95 input-to-visible response <=180 ms; congested
80 ms RTT/3% loss/5 Mbps <=300 ms and at least 50% less freeze time than the
measured old build; controlled handover recovery <=10 seconds after a viable
direct path and signaling are available.

Those targets are not established by a loopback pass or transport-only benchmark.
Two physical Macs still need mixed desktop work, moving 1080p content, Wi-Fi/
hotspot handover, pause/resume, sustained congestion, and real display/input
acceptance. Blocked direct UDP remains an unsupported route; no relay is added.

Use a separate candidate package, record each Mac's OS/hardware, selected path,
VPN/proxy state, test duration and workload, and export diagnostics from both.
Keep the previous app available until the target networks pass acceptance.

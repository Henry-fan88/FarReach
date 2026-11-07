# Direct transport v2

The helper keeps ICE restricted to direct IPv4/IPv6 UDP. TURN configuration,
relay candidates and non-UDP selected paths remain rejected. Device identity
proofs remain bound to the full offer/answer SDP; both Macs need protocol v2.

Video uses H.264 RTP/SRTP with TWCC/GCC, a bounded pacer and deadline-aware NACK
repair. The advertised codec is Main Level 5.1 (`4d0033`), matching the native
Main encoder while allowing a 1920-pixel **long edge** at 60 fps on non-16:9 Mac
displays. This is not a new 4K quality mode. AVCC FRV1/FRV2 and FRS1 generation
envelopes remain the app/helper representation; FRV2 timing is preserved on RTP.

Reliable ordered control and replaceable unordered pointer snapshots use
separate data channels. Local media is split into 16 KiB IPC chunks, allowing
control to run between chunks. A 12-frame / 8 MiB compressed output queue preserves
reference chains released together after packet repair; it is flushed on capture
generation changes. The helper admits video/pointer traffic only
after local media authorization with a nonzero capture generation. New app
builds opt into `mediaFlowControl`: one generation-tagged `mediaCapacity` grant
permits one encoded access unit. The next grant waits until every packet is
enqueued and the pacer—including an in-flight socket write—is drained. This
prevents new encoded references from competing with a recovering IDR. Generation
changes clear pending media and repairs; delayed packets retain their old tag.

The pacer has a 512 KiB / 2048-packet ceiling and accounts for original and
repaired traffic together. Idle intervals refill the token bucket up to its
4800-byte burst ceiling, so frame-grant pauses do not discard available capacity. The actual pacing rate and published encoder budget
have the same 500 kbps floor; `estimatedBitrate` retains the raw congestion
estimate. Original delta admission is bounded by 150 ms of the current rate.
IDRs normally use 500 ms, with a bounded 2 s / 512 KiB fallback for larger valid
recovery pictures; receiver IDR completion also expires after 2 s. Delta completion/repair uses
`clamp(150 ms, 2 × RTT + 100 ms, 350 ms)` to allow two useful round trips without
delaying already complete contiguous frames. Receive storage is capped at
12 access units and 8 MiB of payload. NACK state holds at most 2048 gaps, sends
at most 256 sequence numbers per tick, waits one RTT plus 10 ms between its two
attempts, and stops when repair cannot arrive within the access-unit deadline.
Missing tail packets with no later sequence evidence recover through bounded
expiry and an IDR request. No FEC is enabled.

Statistics separate actual admission/pacing drops, keyframe requests and
dependent-frame suppression; ordinary PLI/FIR requests do not invent congestion.
Statistics report detected RTP sequence gaps and later arrivals separately;
these are not measurements of physical link loss, and later arrivals include
reordering. `targetBitrate` is the host's encoder recommendation, not the
viewer's received bitrate. RTT is not capture-to-display or input-to-visible
latency. Capture timestamps use the host clock and cannot be subtracted from
an unsynchronized viewer clock.

From this directory, `go test -race ./...` runs regression tests. Real loopback
UDP must be available for helper integration tests. Optional controlled tests:

```sh
FARREACH_NETWORK_IMPAIRMENT=1 go test -race ./internal/peer -run TestVirtualWAN -v
FARREACH_NETWORK_IMPAIRMENT=1 FARREACH_NETWORK_BASELINE=1 FARREACH_NETWORK_LONG=1 \
  go test -race ./internal/peer -run '(TestVirtualWANImpairments|TestLegacyVirtualWANBaseline)/RTT80ms_loss3_bandwidth5000000' -v
```

The harness uses real Pion ICE/DTLS/SRTP/SCTP over virtual UDP with synthetic
H.264-shaped payloads. It measures helper delivery, control RTT and frame gaps,
not native decoding, display scanout or real WAN performance. Fixed loss uses
a fixed random seed; the separate dynamic case also adds vnet's random jitter,
five-packet bursts and a 15 → 2 → 15 Mbps bounded bottleneck. Its offered load
must exceed 2 Mbps to verify that the capacity reduction is exercised. The
legacy comparison is a test-only reproduction of the previous zero-retry SCTP
media algorithm, not a production fallback.

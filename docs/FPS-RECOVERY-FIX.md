# FarReach 0.5.1 frame-rate fix

This release addresses keyframe starvation, pacing, and feedback defects reproduced with generated desktop workloads.

## Reproduced defects

- Native H.264 encoding of an ordinary generated text desktop produced initial
  keyframes of 165–184 KB after packetization. The transport allowed only 125 KB
  at its initial 2 Mbps rate. Rejected keyframes never reached the wire, and
  subsequent reference-dependent frames could not be used. Consequently, low
  network gap counts did not imply healthy video delivery.
- PLI/FIR refresh requests and suppression while waiting for a keyframe were
  counted as sender drops. The quality controller interpreted these as severe
  congestion and reduced the encoding rate unnecessarily.
- Encoding could continue while a recovery keyframe occupied the pacer, causing
  more compressed reference drops and further recovery requests.
- The token bucket did not refill for elapsed idle time. A deterministic test
  found zero available bytes after 100 ms idle at 2 Mbps, where its bounded
  4,800-byte allowance should have been restored.
- Cached elevated RTT values and the expected pacing age of a single keyframe
  could repeatedly reduce quality independently of actual congestion feedback.

## Changes

- Apply VideoToolbox `DataRateLimits` over a 0.5-second window with 15% transport
  headroom, alongside average bitrate. Record unsupported hardware fallback;
  the rate limit is not assumed to be an absolute per-frame bound.
- Admit oversized recovery keyframes within a bounded two-second, 512 KiB cap,
  while preserving immediate delivery of complete frames. Keep the existing
  500 kbps native setting floor consistent with the effective pacing budget.
- Use one generation-tagged app/helper media credit per encoded frame. The next
  credit is released after the pacer and its in-flight write drain, not after
  bytes are merely copied into the helper pipe. This is local backpressure, not
  a wait for a remote network acknowledgment.
- Keep one encoder submission reserved through its capture-queue forwarding
  callback. During backpressure retain the newest raw capture, rather than
  producing compressed references that must then be discarded.
- Separate genuine admission/pacing failures from refresh requests and
  intentional dependency suppression. Use GCC's estimate and actual drops for
  adaptation; expected single-frame pacing and RTT alone do not invent extra
  congestion.
- Refill the token bucket after idle time, preserving its 4,800-byte burst cap.
- Carry optional bounded sender measurements in existing authenticated `hello`
  messages: capture/encoder counters, rate-limit support, quality configuration,
  distinct transport counters, and app version/build. Older v2 peers ignore this
  optional JSON field. No screen content, input contents, or addresses are added.

Direct-only routing, device authentication, saved trust, and remote transport
protocol v2 are retained. The private app/helper protocol adds opt-in media
credits; the app and its bundled helper must be installed together.

## Validation and limits

Native rate-limit fixtures encoded and decoded all generated frames. At 500 kbps,
the 1280×800 initial keyframe fell from 100,503 to 25,497 encoded bytes; its RTP
size then fits the ordinary pacing allowance. A real helper regression also
transfers a 200 KB recovery keyframe followed by predictive video without early
or duplicate capacity grants. Continuous predictive-frame, credit/generation,
rate-feedback, and token-bucket regressions cover the reported failure paths.

The detailed continuous test uses generated CoreText scrolling, the production
capture pipeline, Swift IPC, real local WebRTC helpers, and native decoding.
It is a local integration test, not a real two-Mac or physical display benchmark.
Local integration results do not establish physical display performance or successful operation on a particular pair of networks.

The final full Swift run passed 120 cases with two opt-in skips (real Keychain
and the extended encoder-rate experiment). The extended native experiment was
also run separately. All five Go packages passed the race detector. In the final
full-suite continuous run, simple motion presented all 180 frames in six seconds;
detailed text presented 122, with zero Swift send rejections. Those counts include
bootstrap and adaptation and remain synthetic local integration measurements.

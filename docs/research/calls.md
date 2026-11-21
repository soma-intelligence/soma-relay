# Soma Relay calls: research and implementation guide

Date: 2026-11-21. Scope: 1:1 P2P audio and video (WebRTC), iOS via the stasel/WebRTC SPM package (libwebrtc), plus Chrome, Safari and Firefox.
Status legend: **[verified]** read in a source, **[probe]** depends on the exact binary, check at runtime before relying on it.

## 1. Survey (2023-2026)

**Speech codecs.**
- Opus 1.5 (Mar 2024) added ML tools: DRED (about 1 s of VAE-coded redundancy per packet), Deep PLC, and LACE/NoLACE decoder post-filters for SILK. All are off by default, need `--enable-osce` / DRED build flags, and DRED needs jitter buffer cooperation. Opus 1.6 updated the DRED model and broke bitstream compatibility with the 1.5 one. [Opus 1.5](https://opus-codec.org/demo/opus-1.5), [Opus 1.6](https://opus-codec.org/demo/opus-1.6) [verified]
- Neural codecs: SoundStream ([2107.03312](https://arxiv.org/abs/2107.03312)), EnCodec ([2210.13438](https://arxiv.org/abs/2210.13438)), DAC ([2306.06546](https://arxiv.org/abs/2306.06546)), Lyra v2 ([google/lyra](https://github.com/google/lyra), 3.2 to 9.2 kbps), Mimi (Kyutai, about 1.1 kbps at 12.5 Hz, 80 ms frame, in [Moshi 2410.00037](https://arxiv.org/abs/2410.00037)). Gains below 6 kbps are real, but none has a standard RTP payload or a libwebrtc audio path.

**Video codecs.**
- Learned video coding: DCVC-FM ([2402.17414](https://arxiv.org/abs/2402.17414)) and DCVC-RT ([2502.20762](https://arxiv.org/abs/2502.20762), CVPR 2025). DCVC-RT reports 1080p real-time on desktop GPUs (about 7.8 ms network inference per frame on the paper's setup) and about 21% fewer bits than VTM. Still GPU-class, no phone encoder, no RTP, no hardware path. [verified]
- Keypoint/generative face codecs: face-vid2vid ([2011.15126](https://arxiv.org/abs/2011.15126)), NVIDIA Maxine AI video compression. Very low bitrate, but needs a GPU, can hallucinate expressions, and breaks the "what you see is what they sent" guarantee.
- AV1 real-time: SVC (L1T3 and friends, [AV1 RTP spec](https://aomediacodec.github.io/av1-rtp-spec/)), screen-content tools (palette, intra block copy). Software encode on phones is costly. libwebrtc iOS has no VideoToolbox AV1 encoder. A17 Pro and M3 and later have AV1 hardware decode only.
- HEVC: hardware only in browsers. Safari has shipped it in WebRTC, Chrome aligned on HW-only with no software fallback ([Chromium intent](https://groups.google.com/a/chromium.org/g/blink-dev/c/3h8lL8a377c)). Not a clear win over H.264 + AV1 for us and patent-encumbered. VVC: no real-time WebRTC path.
- WebKit reports AV1 WebRTC decode as supported on M3+/A18+ but not "smooth/powerEfficient" ([WebKit bug 311593](https://bugs.webkit.org/show_bug.cgi?id=311593)). Treat AV1 on Safari as opportunistic. [verified, 2026]

**Congestion control and loss.** GCC (transport-wide-cc, delay plus loss based) is the only production-proven option inside libwebrtc. SCReAM ([RFC 8298](https://www.rfc-editor.org/rfc/rfc8298)) and L4S ([RFC 9330](https://www.rfc-editor.org/rfc/rfc9330), [RFC 9331](https://www.rfc-editor.org/rfc/rfc9331)) are not in libwebrtc, and L4S needs network support we do not control. Loss: NACK + RTX for video on low RTT, Opus in-band FEC (LBRR) and RED for audio, optional ULPFEC/FlexFEC for video on high-loss links.

**E2EE.** SFrame is [RFC 9605](https://www.rfc-editor.org/rfc/rfc9605) (frame-level AEAD, per-sender key ids and counters). Browsers expose it through [WebRTC Encoded Transform](https://www.w3.org/TR/webrtc-encoded-transform/): `RTCRtpScriptTransform` (worker) and an `SFrameTransform` in the spec. Native `SFrameTransform` shipping is uneven, so assume `RTCRtpScriptTransform` plus our own WebCrypto code. [verified: spec exists; per-browser shipping state is [probe]]

## 2. What is shippable today

### iOS (stasel/WebRTC SPM, libwebrtc xcframework)
- Default encoder factory gives: H.264 (two profiles, VideoToolbox hardware), VP8, VP9 (software). AV1 appears only if the binary was built with `RTC_USE_LIBAOM_AV1_ENCODER`; **[probe]** by logging `RTCDefaultVideoEncoderFactory.supportedCodecs()` and `RTCDefaultVideoDecoderFactory.supportedCodecs()` at launch and keep that log in the call-quality telemetry. HEVC is not in upstream default factory; do not plan on it. [verified for upstream source](https://searchfox.org/firefox-main/source/third_party/libwebrtc/sdk/objc/components/video_codec/RTCDefaultVideoEncoderFactory.mm)
- Hardware AV1 decode through VideoToolbox is not wired into libwebrtc's ObjC decoder factory. Even on A17 Pro/M3, expect the software dav1d/libaom path unless we add our own `RTCVideoDecoderFactory` wrapping `VTDecompressionSession` (a reasonable later task).
- Codec preference: `RTCRtpTransceiver.setCodecPreferences(_:error:)` with codecs reordered from `RTCRtpSender.capabilities(for: .video)`. Must be called before `createOffer`/`createAnswer`.
- Encoding parameters (ObjC `RTCRtpEncodingParameters`): `maxBitrateBps`, `minBitrateBps`, `maxFramerate`, `scaleResolutionDownBy`, `networkPriority`, `bitratePriority`, and `scalabilityMode` in recent builds **[probe]**. Set through `sender.parameters` then reassign.
- Connection-wide: `RTCPeerConnection.setBweMinBitrateBps(_:currentBitrateBps:maxBitrateBps:)` to seed GCC (start 600 kbps, max 1.6 Mbps).
- Audio: Opus is built in. FEC, DTX, ptime are controlled by SDP fmtp (see section 3). Opus in libwebrtc is a pinned libopus without DRED enabled.
- Audio session: `RTCAudioSession` with `AVAudioSessionCategoryPlayAndRecord`, mode `voiceChat` (hardware AEC/AGC/NS via VoiceProcessingIO), `setPreferredIOBufferDuration(0.01)`, 48 kHz.
- Frame encryption: **upstream ObjC does not expose `FrameEncryptorInterface` or a frame transformer, and I could not confirm stasel's package does.** Plan in section 4.

### Browsers
| | Chrome | Safari | Firefox |
|---|---|---|---|
| Opus (FEC, DTX, RED) | yes | yes (RED varies) | yes |
| H.264 | yes | yes (HW) | yes (OpenH264, some HW) |
| VP8 / VP9 | yes / yes (L1T3 via `scalabilityMode`) | yes / yes (recent) | yes / yes |
| AV1 | yes, SVC modes | decode on M3+/A18+, not smooth by default | yes (decode, encode partial) |
| HEVC | yes, HW only | yes | no |
| `RTCRtpScriptTransform` | yes | yes | yes |
| `jitterBufferTarget` | yes | **[probe]** | **[probe]** |

Browser rows are my best reading of the cited sources; confirm with `RTCRtpSender.getCapabilities('video')` at runtime and negotiate down.

## 3. Concrete settings

### Codec order (video)
Goal: lowest latency and battery first, quality second.
- **iOS <-> iOS:** H.264 (VideoToolbox HW both ends, ~30 ms glass to glass), profile `42e01f` (Constrained Baseline L3.1) for max compatibility, `640c1f` (High) if both report it. Use this by default. Do not send AV1 or VP9 from a phone: software encode kills battery and adds latency.
- **Web <-> web (Chrome/Firefox):** AV1 with `L1T3` if both sides advertise it, else VP9 `L1T3`, else H.264.
- **iOS <-> web:** H.264 (Safari and iOS both have HW). AV1 only for the downlink to an iPhone when the sender is a desktop Chrome and the iPhone reports AV1 decode.
- **Screen share (desktop senders):** AV1 with `contentHint = "text"` or `"detail"`, fall back to VP9.
- Order in `setCodecPreferences`: put the chosen codec first, then H.264, VP8 last; keep `rtx`, `red`, `ulpfec` entries after. No HEVC in v1.

### Video ladder (1:1 mobile, single stream, no simulcast)
Let GCC pick, but constrain it. Set `maxFramerate = 30`, `degradationPreference = "maintain-framerate"` (people notice frame rate drops more than resolution on a face), `contentHint = "motion"`.

| Step | Resolution | fps | Bitrate (H.264) | Bitrate (AV1/VP9) |
|---|---|---|---|---|
| 5 | 1280x720 | 30 | 1.2 to 1.6 Mbps | 0.8 to 1.1 Mbps |
| 4 | 960x540 | 30 | 700 to 1100 kbps | 450 to 700 kbps |
| 3 | 640x360 | 30 | 350 to 600 kbps | 220 to 380 kbps |
| 2 | 480x270 | 24 | 180 to 320 kbps | 120 to 200 kbps |
| 1 | 320x180 | 15 | 90 to 160 kbps | 70 to 120 kbps |
| 0 | audio only | n/a | below 60 kbps total | |

Rules: `maxBitrate` 1.6 Mbps cap on cellular, 2.5 Mbps on Wi-Fi 720p. `minBitrate` 80 kbps. When GCC estimate falls below 150 kbps for 4 s, drop video, keep audio, show a "video paused" state, retry every 10 s. Keyframe on loss: rely on PLI, rate limit to one per second.

### Audio
Voice calls are the priority. Audio gets `networkPriority = "high"`, `priority = "high"`.

| Condition | Opus bitrate | Bandwidth | ptime | FEC/DTX |
|---|---|---|---|---|
| Good (loss < 2%) | 24 to 32 kbps | wideband to fullband | 20 ms | FEC on, DTX on |
| Mid (loss 2 to 8%) | 16 to 24 kbps | wideband | 20 ms | FEC on, DTX on |
| Bad (loss > 8% or BWE < 300 kbps) | 8 to 12 kbps | wideband | 40 ms | FEC on, DTX on, RED if available |

Why not 6 kbps by default: Opus 1.5 improved wideband at 6 kbps but it is still clearly lower quality than 16 to 24 kbps; save it for the worst tier.

SDP (munge only the fmtp of `opus/48000/2`, and only if the API does not already set it):
```
a=fmtp:111 minptime=10;maxptime=40;useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0;maxaveragebitrate=32000;maxplaybackrate=48000;cbr=0
a=ptime:20
```
Keep `maxptime=40`, not 60, to bound latency. In Chrome and libwebrtc builds, `usedtx=1` only lowers bandwidth during silence; keep comfort noise on. `RTCRtpEncodingParameters.ptime` is not reliably supported, so ptime adaptation is done by re-negotiation or by libwebrtc's own audio network adaptor **[probe]**; if not available, stay at 20 ms.

### getUserMedia (web)
```js
audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true,
         channelCount: 1, sampleRate: 48000, latency: { ideal: 0.01 } },
video: { width: { ideal: 1280 }, height: { ideal: 720 },
         frameRate: { ideal: 30, max: 30 }, facingMode: 'user' }
```
Leave AEC/NS/AGC on. Only turn them off for a music mode, which we do not ship.

### Latency
- Receiver: `receiver.jitterBufferTarget = 40` (ms, Chrome) for voice, 80 for video; never 0, it trades latency for glitches. Leave libwebrtc's adaptive NetEq on.
- Sender: do not use `playoutDelayHint` unless a measured need; default adaptive is already low on P2P.
- Prefer direct P2P (host/srflx). Always provide TURN (UDP first, TCP/TLS 443 as last resort). Offer a "relay only" privacy switch, it costs 20 to 80 ms.
- Target: one-way mouth-to-ear under 150 ms on a healthy link. Log `jitterBufferDelay/jitterBufferEmittedCount`, RTT, `packetsLost`, `freezeCount`, `qualityLimitationReason` once per 2 s into local telemetry.

### Loss resilience
- Audio: in-band FEC + DTX always; add RED (`audio/red`) in browsers when loss > 5%.
- Video: NACK + RTX on (default). PLI for keyframes. Enable FlexFEC only through field trial if RTT > 150 ms.
- L1T3 temporal layers (VP9/AV1) let a relay drop T2/T1 under congestion without a keyframe; useful once we add group calls or a relay.
- No L4S, no SCReAM in v1.

## 4. E2EE plan

**Threat model:** DTLS-SRTP already encrypts media between peers, but its key exchange is classical (ECDHE), so recorded calls are exposed to a future quantum adversary, and a malicious TURN/SFU or signaling server could swap fingerprints. Our PQ session fixes both.

**Design (SFrame-like, RFC 9605 profile):**
1. Per call, derive from the PQ session (ML-KEM based, already authenticated): `call_secret = HKDF-SHA256(session_secret, salt = call_id, info = "soma-relay call v1")`, 32 bytes.
2. Derive directional keys: `k_send = HKDF(call_secret, "send" || sender_id)`, with distinct audio/video key ids. Counter `CTR` per sender, 64-bit, never reused.
3. Frame format: SFrame header (KID, CTR) + ciphertext + tag. Cipher suite: AES-256-GCM with 16-byte tag (RFC 9605 AES_GCM cipher suites). Use RFC 9605 wire format so that a later SFU or a native `SFrameTransform` works unchanged. Authenticate the media codec header as AAD.
4. Leave the codec payload header bytes in clear so the RTP packetizer still works: VP8 first 1 to 3 bytes, H.264 NAL header (plus slice header byte), VP9/AV1 descriptor bytes, 1 byte for Opus TOC is not required (Opus can be encrypted whole).
5. Ratchet: new key every 5 minutes or on a participant change (`k_{n+1} = HKDF(k_n, "ratchet")`), keep the previous key for 10 s of overlap. Zero keys on hang up.
6. Also sign and verify the DTLS fingerprints in the SDP with the PQ session, so even if SFrame were bypassed the DTLS handshake is bound to the PQ identity.
7. Show a call-verification code (hash of both identity keys + call_secret) in the UI.

**Web:** implement in a worker with `RTCRtpScriptTransform` (works in Chrome, Safari, Firefox) using WebCrypto `AES-GCM`. Use native `SFrameTransform` only when `typeof SFrameTransform !== 'undefined'` and after interop tests.

**iOS, if stasel does not expose a frame encryptor** (most likely; check for `RTCFrameCryptor`, `RTCFrameEncryptor`, `frameTransformer` symbols in the xcframework headers):
- **Option A (recommended):** move to the LiveKit-maintained fork `webrtc-sdk/webrtc` ([github](https://github.com/webrtc-sdk/webrtc)), which ships `RTCFrameCryptor` and key providers in the ObjC API. Same libwebrtc core, so SDP and codec behavior stay the same. Then implement our framing in a small patch or use its AES-GCM cryptor and match its frame layout on the web side (our worker produces the same layout). Pin the version, keep a smoke test that two call endpoints interop.
- **Option B:** build libwebrtc ourselves with a thin `FrameEncryptorInterface`/`FrameDecryptorInterface` wrapper exposed to Swift (about 300 lines of C++/ObjC++). More control, more build burden.
- **Option C (stop-gap, not E2EE-PQ):** run on DTLS-SRTP only, with fingerprints signed by the PQ session (step 6). This is acceptable for an internal alpha, not for the "post-quantum" claim. Do not ship publicly with only C.
- Do not try to rewrite frames in audio/video capture callbacks (custom `RTCVideoEncoder` wrappers): it breaks hardware codecs and RTP packetization.

## 5. Research upgrade path (later, and why not now)
1. **Opus DRED + deep PLC (first upgrade):** build libopus 1.6 with DRED and wire it to libwebrtc's audio encoder/decoder and NetEq. Big loss resilience gain for cellular. Not now: it is not exposed by libwebrtc, the bitstream is version-sensitive (1.5 vs 1.6), and the jitter buffer integration is non-trivial. Interop with browsers would break unless negotiated as an optional capability.
2. **Neural speech codec (Lyra v2, Mimi class) at 1 to 6 kbps:** worthwhile only for extreme links. No standard RTP payload, own PLC, 5 to 20 ms extra CPU latency, battery, and a custom `AudioEncoder`/`AudioDecoder`. Do it as a negotiated optional codec after DRED.
3. **VideoToolbox AV1 decode and a custom decoder factory on iOS:** cheap, real win for AV1 downlink. Do after the E2EE work.
4. **Learned video (DCVC-RT) and talking-head keypoint codecs:** require GPU-class inference, have no hardware path on phones, no RTP, and generative modes can misrepresent a face. For a messenger positioned on trust, ship only as an explicit opt-in "ultra low bandwidth" mode on A17 Pro/M-class devices, after a privacy and misrepresentation review.

## 6. Do now (order)
1. Log supported codecs on iOS and web; confirm stasel exposes or not a frame cryptor.
2. Decide Option A or B for iOS frame encryption; build the RFC 9605-style transform on both sides.
3. Ship H.264 default on iOS, AV1/VP9 L1T3 on web, the ladder and Opus settings above.
4. Add the telemetry fields and run a loss/latency test matrix (0, 2, 8, 15% loss; 50, 150, 300 ms RTT; 300 kbps to 3 Mbps).
5. Later: DRED, VT AV1 decode, optional neural modes.

# EasyConn session for the Zontes 368G: what the Android app does

Taken from the Android app (`moto-hub/apps/android/.../tbox/RideDaemonTransport.kt` and
neighbours) on 2026-11-07, for the Zontes 368G profiles E/F/G only. File:line references are to
that repository.

## Connection

- The dash is a WPA2 access point (`ZT_…`). The phone joins it; the dash is the subnet gateway.
- The 368G answers the EasyConn **wake probe** on TCP **10930** but does not advertise over mDNS.
  - Frame: 16-byte little-endian header `[cmd 0x70000010][totalLen = 16 + body][cmd ^ totalLen][0]`
    then the body `{"phoneType":"Android","packageName":"<id>"}`.
  - Acknowledgement: cmd `0x70000011`, the XOR must hold, the body contains `"true"`.
  - Identities tried in order (first one 3 times, 1 s apart; others once):
    `com.cfmoto.cfmotointernational`, `net.easyconn.easyride.wws`, `net.easyconn.carman`,
    `com.carbit.easyconnect`. The winner is tried first next time.
- **EC init** goes to the same host:10930 carrying the *acknowledged probe package* (not the
  client package). Go can dial it itself: `SetECHost(NewStreamHost(ip, "10930", pkg))` +
  `StartSession()`. It blocks until the dash's first PXC heartbeat (startup timeout 25 s).
- The dash then **connects back** to the phone on 10922 (PXC), 10921 (media control) and
  10920 (media stream); Go listens on those ports.
- Never reuse a `MobileSession` after a failed start: `StopSession` on a session that never ran
  marks it stopped forever. Make a fresh one per attempt.

## MobileConfig (E / F / G)

`NewMobileConfig(empty, 30, 25, 5, 10, 3)`, then:

| Field | E | F | G |
|---|---|---|---|
| SupportFunction | 0 | 0 | 128 |
| ProactivePxcHeartbeatEnabled | true | true | true |
| PlainVideoFramingAllowed | true | true | true |
| ClientPackage | tayo.com.ZontesIntelligence | same | same |
| PhoneBrand / PhoneModel | phone's (SM-F711B on the test phone) | same | same |
| PhoneOsVersion | SDK level ("35") | same | same |
| ClientVersionCode / Fingerprint | 0 / "" (Go default 121) | 3034 / `V:1.12(3034)--ONLINE` | same as F |
| ClientInfoSupportFunction | false | false | true |

Also TimeZoneID / TimeZoneOffsetSeconds from the device, SkipDashClockSync false, DashAsksForTime
false. Go hard-codes PhoneOs "Android".

## Callbacks

`OnError(msg, fatal)`, `OnEvent(time, source, command, payload)`, `OnStopped()` - each on its own
goroutine, unordered.

- source 3 (media control), cmd 16 = CAPTURE_CONFIG: `u16le width @0, u16le height @2`. Go replies
  with `width & ~15, height & ~15` itself, so the stream must be exactly that (1280x535 → 1280x528).
- source 3, cmd 112 = STREAM_START: Go clears its queue and waits for an IDR. **Send an IDR.**
- source 2 = PXC JSON (0x10010 CLIENT_INFO, 0x10450 QUERY_TIME): informational.
- source 4, cmd 2 = video pulls `[phase, u64 BE]` (0 socket open, 1 first pull, 2 progress, 3 closed).

## Frames

- `PushFrame` takes exactly one access unit, Annex-B or AVCC; SPS+PPS must precede each IDR.
- Go keeps a ring of 6 AUs, drops everything until an IDR at start, after STREAM_START and after
  3 s without input. ReplayKit only delivers changed frames, so re-encode the last one every 100 ms.
- Encoder for E/F/G: 1280x528, 30 fps, 2.5 Mbps × quality, 1 s GOP of plain IDRs, Baseline 3.1.

## What the official ZONTES app sends (2026-11-07)

moto-hub never painted the 368G either (it pulled thousands of frames over the pairing QR), so
the reference is the official app's EasyConn SDK, `build/zontes-jadx/sources/net/easyconn/carman/`:

- Each pull is answered with `u32 LE length` + the raw MediaCodec output; an idle pull with four
  zero bytes. SPS+PPS go in front of the first IDR in the same payload. No AUD, no SEI, no frame
  index; the 8-byte timestamp is only for "movie mode" (`supportFunction & 1`).
- The encoder is re-created at level 3.1 if the SPS level is above 31 (`HardCodecUtil`), and the
  SPS is found by the literal header byte `0x67`. I-frame interval 3 s.

Smart Auto therefore sends no AUD (hudlib `BuildAnnexBAU`), rewrites VideoToolbox's NAL headers
(`0x27/0x28/0x25/0x21`) to MediaCodec's (`0x67/0x68/0x65/0x41`) and drops SEI/AUD
(`Shared/H264NAL.swift`), and logs `Video framing: extended=… plain=…` and the first keyframe's
bytes. Profile H sends only the "mirror is live" app status (`AppStatusLiveOnly`): the 368G reset
the 10922 socket right after the "connected" one.

The iCarCast relay (CarPlay direct) is High profile, level 4.2, 60 fps, which the official app
would never send this dash; it would need re-encoding to Baseline 3.1 to match.

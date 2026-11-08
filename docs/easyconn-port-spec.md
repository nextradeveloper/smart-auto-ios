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
bytes.

Field log 2026-11-07 (build 23): the dash then received exactly that (`67 42 00 1f`, Baseline
3.1, 1280x528, `[67,68,65]`, plain framing) and pulled it, and still kept its pairing page up.
The picture was never the problem; the dash is never told the phone app is there:

- `MediaProjectService.sendCurrentStateToCar` sends `ECP_P2C_APPSTATUS_FOREGROUND` (0x20020) while
  the app's screen shows (`isOnForeground()`), `ECP_P2C_APPSTATUS_BACKGROUND` (0x20030) otherwise.
  Same body: `{"displayRotation","width","height","enableAccessibility","enableAOAHid","mode"}`,
  width/height the phone's real display. Mode 1 = true mirror, 2 = the app's own car screen (its
  normal state, the Mapbox presentation), 3 = split with overlay. ZONTES' listener does not
  override `isSendCurrentMirrorStateBySelf`, so the SDK sends it.
- When: on PXC connect (`EcManager.onPxcConnected`), on EasyConnect plus one second, then every
  second while PXC is up (`EcBridge` `FORCE_GROUND_CHECK`, `sendEmptyMessageDelayed(…, 1000)`), and
  on activity pause.
- The old profile H sent BACKGROUND mode 2 the instant CLIENT_INFO was answered; the 368G reset
  10922 within milliseconds.

Profile H now sends FOREGROUND mode 2 every second from one second after the dash's first PXC
heartbeat (hudlib `SetAppStatusRepeat`); profile I the same with mode 1. Body: 1080x2640 upright,
the SM-F711B this identity claims. A dash that knows the command acks `0x20021`, visible in the log
as `PXC 0x20021`. CLIENT_INFO (0x10010) is now logged in full for its `mirrorMode`: 2 makes the
official app use true mirror (mode 1).

The iCarCast relay (CarPlay direct) is High profile, level 4.2, 60 fps, which the official app
would never send this dash; it would need re-encoding to Baseline 3.1 to match.

Field log 2026-11-08 (build 24): FOREGROUND mode 2 went out every second on CAR_CTRL; the 368G kept
the session 40 s but never acked (no `0x20021`) and painted nothing. Its CLIENT_INFO: `mirrorMode`
1, `productType` 3, `flavor` 65561, `screenType` 1, `sdkVersion` 0.9.29.1, channel 21334.

RideScreen AA (github.com/mgb1982/ridescreen-aa, AGPL, a fork of open-cfmoto) reports the whole
Zontes 368 range working. From its `PxcHandshake.kt`, field-tested on Zontes dashes: the official
app sends `0x20020` (mode 2, enableAOAHid true, phone's portrait size) on the **CAR_DATA** socket
~130 ms after the dash opens it, then every second, and sends CHECK_SN_RESULT on CAR_DATA too; the
dash acks `0x20021`. It identifies as `com.cfmoto.cfmotointernational` versionCode 126 and
answers each frame pull with `u32 LE length + Annex-B`, Baseline 3.1, IDR every second.

hudlib now routes both to CAR_DATA (`appStatusConn`, `namedConn`). Profile H keeps the ZONTES
identity; profile I uses RideScreen's.


Field log 2026-11-08 (build 25): screen share paints on the 368G with profile H. The dash acks
`0x201C1` (CHECK_SN_RESULT on CAR_DATA) and `0x20021` every second. CarPlay direct could not reach
iCarCast in that log at all (its "This iPhone" server was not running). The relay now applies the
same NAL header rewrite as screen share; its picture is still iCarCast's High-profile H.264, and
this app cannot re-encode it while in the background.

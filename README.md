# Smart Auto for iPhone

ส่งภาพหน้าจอ iPhone (เช่น CarPlay จากแอป iCarCast โหมด *This iPhone*) ขึ้นจอ Zontes 368G ผ่านโปรโตคอล EasyConn โดยใช้ iPhone เครื่องเดียว

Sends the iPhone screen (for example CarPlay drawn by iCarCast's *This iPhone* mode) to a
Zontes 368G motorcycle dash over EasyConn, with no second phone.

## How it works

```
iCarCast (CarPlay on this iPhone, in front)
        │ screen
        ▼
ReplayKit broadcast upload extension  ── SmartAutoBroadcast/
  VideoPipeline: rotate + scale to 1280x528, H.264 Baseline 3.1, IDR every 1 s, 100 ms repeat
  DashSession:   wake probe :10930 → EC init → Go hudlib session (dash connects back on 10920-10922)
        │ Wi-Fi (the dash's own AP, ZT_…)
        ▼
Zontes 368G dash
```

- `SmartAuto/` — the app: start button (system broadcast picker), dash test, settings, log.
- `SmartAutoBroadcast/` — the broadcast extension. iOS keeps it running whichever app is in
  front, so the dash link lives here. Memory limit is about 50 MB.
- `Shared/` — settings/status/log through the app group, dash identity profiles, dash locator.
- `hudlib/` — snapshot of the ridedaemon-lib fork (GPLv3) used by the Android app; see
  `hudlib/SOURCE.txt`. CI turns it into `Frameworks/Api.xcframework` with gomobile.
- `docs/easyconn-port-spec.md` — what the Android app does around the Go library, which this
  port reproduces.

The dash identity defaults to profile **G** (the official ZONTES companion, version 1.12 (3034),
echoing the dash's supportFunction); E and F can be picked in Settings.

## Building

There is no Mac in the loop: `.github/workflows/ios.yml` builds on a GitHub macOS runner.

1. `gomobile bind -target=ios` builds `Api.xcframework` from `hudlib/`.
2. `xcodegen generate` creates `SmartAuto.xcodeproj` from `project.yml`.
3. `xcodebuild` builds the app (unsigned for now; TestFlight signing comes once the Apple
   Developer account and an App Store Connect API key are in the repository secrets).

## Using it

1. Settings › Wi-Fi: join the bike's Wi-Fi (`ZT_…`).
2. Open Smart Auto, tap **ทดสอบหาจอรถ** (allow Local Network the first time).
3. Tap **เริ่มส่งภาพขึ้นจอรถ** → Smart Auto → Start Broadcast.
4. Open iCarCast › This iPhone and turn the phone to landscape.

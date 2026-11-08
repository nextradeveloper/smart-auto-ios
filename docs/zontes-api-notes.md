# ZONTES Smart integration notes

Research date: 2026-11-07. Sources used were the user's `Zontes Smart 1.12` XAPK,
the live web assets referenced by that app, the user's iOS network captures, and the
provided iOS stackshot. No account credentials or live vehicle commands were used while
researching or testing.

## Confirmed account/data flow

The 1.12 app embeds the web app rooted at:

`https://m.zontes.com/BoxApp/ABROAD/`

Login is a form POST to `ashx/UserCenter/UserInfo.ashx` with:

- `method=login`
- `logintype=SPLogin`
- `name=<account email>`
- `pwd=<lowercase MD5 of the password>`
- `language=en`

Successful responses include `accessToken`, `tokenTime`, `UserCode`, `SignCode`,
`MyMotorCode`, `mcuid`, `imsi`, and ownership state. Smart Auto does not retain the
plain-text password. The returned session is stored in the iOS Keychain.

The home snapshot is a form POST to `ashx/Index/Index.ashx` with `method=getIndex`,
`ACCESSTOKEN`, and `language`. Its response includes `myCarData`, `CarLocation`, online
state, and `imgPath`. Vehicle artwork is constructed from `imgPath`,
`/GX/Box/MotorPic/`, and the vehicle's `IndexImg` (falling back to `NameImg`). The official
Android client also stores and displays `IndexImg`; `NameImg` can be a model wordmark rather
than vehicle artwork.

Observed telemetry fields include fuel percentage, estimated range, lock state, battery
voltage, tire pressures, maintenance distance, satellite count, and update time.

## Confirmed control transport

Remote controls do not use the home REST endpoint. The official app opens a TCP connection
to the vendor command service on port 4510, sends a user/device handshake, then a vehicle
command. Each lock, unlock, or find command contains the authenticated user code, bound PKE
code, and a time-based proof derived from the bound MCU identifier. The implementation in
`VehicleCommandClient.swift` mirrors the 1.12 client format, requires an explicit UI
confirmation, and waits for the matching `*AO` acknowledgement (`1` lock, `2` unlock,
`3` find) before reporting success.

The acknowledgement proves that the vendor command service accepted the command; the app then
refreshes the home snapshot because this still does not prove the physical action completed.

## Bluetooth controls

The official client uses Nordic UART service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` for
lock (1), unlock (2), fuel lid (5) and seat (6): `*BT,{PKE},10,008#` asks for a 4-byte
challenge, then `*BT,{PKE},10,001,{action},{signature}#` (1.12 `vf9.a`). The AES key is
`AES-ECB("TAYOBTa1YCWc2gTS", MCUID)` with the challenge XORed into bytes 12–15 and the
vehicle's **Bluetooth password** (6 digits read as 3 hex bytes) XORed into bytes 0–2.

The owner reports that the ZONTES vehicles use the Bluetooth password `000000`, so Smart Auto
signs with it and does not ask for one. (The 1.12 bind screen can set another password with
`…,10,001,11,{signature},{new password}#`; a vehicle with a different one answers
`*AT,{PKE},10,001,{action},0#`.)

The vehicle also reports state without an action: every challenge reply carries the battery
voltage in tenths of a volt (`*AT,{PKE},10,008,{challenge},126…#` is 12.6 V), and the reply to
the prime frame `*BT,{PKE},10,001,7#` carries the lock state (`…,7,1#` locked, `…,7,2#`
unlocked). Smart Auto primes on connect, asks for one challenge 1.2 s later to read the
battery, and lights Lock or Unlock from those replies and from acknowledged commands. Frames are
written to the app log with the PKE code masked and signatures dropped.

## Vehicle artwork

The official app does not show the account's `IndexImg`. While binding, the owner picks a
model and colour from `GET https://tayo.zontesmotor.com/zontespkeapp/api/GX/PKE/MotorImg/getMotorType/{code}`
(`{code}` is the model-family field of the PKE's QR label), and the app keeps that style's
`imagePath + indexImg` locally. The service groups codes by tens: `001` (350/368/703 ranges),
`010` (125–175 scooters) and `020` (368G/400G/250G). For example the account may return the
2024 high-seat "368G Gray" render while the owner picked "368G Gray (ETC)". Smart Auto
lets the owner pick from the same catalog and stores the choice per PKE code. The same catalog
names the model ("ZONTES 368G") when the account has no name for the vehicle.

## Other findings

- The `.ips` is a system stackshot, not an HTTP archive. It confirms the foreground
  `ZONTESSmart` process and widget extension but contains no request bodies or API schema.
- The IP-based HTTP endpoint seen in the capture is still reachable, but app 1.12 uses the
  HTTPS hostname `tayo.zontesmotor.com` for its newer REST constants. Smart Auto uses the
  live HTTPS web-account flow above and does not embed the captured Basic authorization
  value or Mapbox token.
- Carbit and Mapbox requests in the captures serve projection/navigation and map rendering;
  they are not required for account login or the vehicle image.

## Finding the vehicle (Thai models)

The remote find command (`*UF` over TCP 4510) needs the vehicle's 4G module, which Thai models
do not have (the account shows them offline). The 1.12 BLE protocol has no find, horn or beep
action either: its actions are 1/2/5/6, plus `AT+` frames for ambient light, settings, APN and
reset. Smart Auto finds the vehicle from the phone instead (`FindVehicleView`):

- **Parked spot.** `ParkingSpotTracker` saves the phone's location when Lock is acknowledged
  (the phone is beside the vehicle) and when the Bluetooth link drops as the rider walks away,
  also in the background (`bluetooth-central` background mode, "Always" location). After a drop
  the Lock spot from the same connection is kept if it is within 80 m, since the drop happens
  20–50 m from the vehicle; otherwise the drop spot is used.
- **Signal.** While the screen is open the app reads the link RSSI twice a second and shows a
  rough distance band, vibrating quicker as it gets closer.
- **Chirp.** The vehicle beeps and flashes only when its lock state changes: a Lock sent to a
  locked vehicle is acknowledged (`…,001,1,1#`) but silent (seen on the owner's 368G with the
  engine off). So "make the vehicle beep" unlocks and locks again (retrying the lock up to three
  times), or just locks an unlocked vehicle. It is not recorded as a parking event.

A challenge request can be answered late, after the next one: the vehicle then refuses an action
signed with the earlier challenge (`…,001,5,0#` right after an extra `…,10,008,…#`). The app
keeps the newest challenge seen while waiting for the acknowledgement and signs once more with it.

If the app is force-quit, iOS does not wake it when Bluetooth drops; the spot then updates at the
next Lock.

## Smart Auto's own dash screen (2026-11-08)

Screen share stops when the phone locks, and iOS takes the hardware video encoder from an app in
the background. Step 1 tests the alternative: `SmartAuto/OwnDash/` draws its own picture with Core
Graphics, converts it with Accelerate, encodes it in software with minih264e
(`Vendor/minih264`, CC0: Baseline level 3.1 at 1280x528, the same SPS bytes screen share sends),
and sends it through the same DashSession as screen share; location updates keep the app running
when locked. The log tag is `OWNDASH`: one line every 10 s with fps, draw/encode time, frame size
and whether the phone is locked.

The phone-locked test worked on the 368G. Round A of the real screen (`DashScreenService`,
`DashRenderer`, `DashMap`) replaces it: a CarPlay-Dashboard-style layout (Apple Maps snapshot on
the left, time and ride/bike cards on the right) at 12 fps, opened from the new **จอรถ** tab. The
Bluetooth monitor now lives in `MainShellView` so the dash can show battery and lock state. The log
records whether `MKMapSnapshotter` renders with the phone locked ("Map snapshot ok/failed (phone
locked)"), which decides how much round B (navigation) relies on maps prepared in advance.

Round B (2026-11-08): place search (`MKLocalSearchCompleter`) and turn-by-turn guidance on the
dash (`DashNavigation.swift` logic, `DashNavigator.swift` state). Apple's route steps carry no turn
type, so the arrow comes from the change of heading 25 m either side of each step. Guidance turns
the map to our heading (2048 px square pictures at 1.25 m/px) and draws the route over it; pictures
every 300 m along the first 15 km are made when guidance starts and kept in Caches/DashMaps for when
the phone is locked. Movement between GPS fixes is carried forward and eased (`DashMotion`) at
20 fps; without that the map jumped once a second.

Field log 2026-11-08 17:00 (photos on the bike): 20 fps steady, draw 3-20 ms, encode 2-6 ms, so the
stutter was not the encoder. Parked, GPS wandered a few metres a second and the map followed it;
`DashMotion` now holds still under the fix's accuracy when the speed is under 0.8 m/s. The first
map snapshot took 107 s and blocked all others: snapshots now give up after 12 s, and the last
overview picture is kept on disk (per theme) and shown at once on start. Added: map theme (dark /
light / follow the iPhone), route options (avoid highways, avoid tolls via
`MKDirections.Request.highwayPreference/tollPreference`), and the จอรถ tab shows a live preview of
the dash with the search bar, recent places and the turn card under it.

Heading (2026-11-08): the map turned late because GPS course updates once a second and only when
moving, and the Dashboard map did not turn at all. `DashMotion` now learns, while riding above
4 m/s, the angle between the phone's compass and the GPS course; once that holds steady (phone in a
mount) compass plus the angle is the heading, live and also stopped. In a pocket it never steadies
and GPS course is used. The Dashboard map turns too (square 1280 px pictures). The phone's
full-screen map is landscape with the dash's layout (OrientationLock in SmartAutoApp.swift).

## Camera unit (DVR) on the bike's Wi-Fi

`http://192.168.3.1:7686`, JSON POST to the root, as the official app's `a/cb3.java` sends it:
`{"METHOD":"VIDEO.DATE","previewType":"front|rear"}` → `dateList`; `VIDEO.TIME` with `date` →
`timeBeanList`; `VIDEO.INFO.LIST` with `date`, `time`, `index`, `num`, `sort` → `videoBeanList`
(`playUrl`, `thumbUrl`, `title`, `name`; URLs may lack the scheme); `PICTURE.INFO.LIST` with
`previewType: all` → `pictureBeanList` (`pictureUrl`); `LOG.FILE.LIST` → `logList`. The official
app has no live view (its only RTSP reference is ExoPlayer's timeout constant). Smart Auto's
camera page (`SmartAuto/Dashcam/`) plays and saves recordings, and "ทดสอบภาพสด" probes ports,
RTSP and HTTP paths and JSON methods for a live stream; results go to the log under `CAM`.

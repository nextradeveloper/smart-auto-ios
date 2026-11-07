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

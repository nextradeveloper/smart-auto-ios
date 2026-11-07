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

## Bluetooth status

The official client uses Nordic UART service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` (plus
legacy service `A041`) for nearby BLE functions. Smart Auto scans only those services and
reports Bluetooth power, nearby, and system-connected states. It deliberately does not seize
or pair a nearby peripheral automatically, which could interrupt the official app.

## Other findings

- The `.ips` is a system stackshot, not an HTTP archive. It confirms the foreground
  `ZONTESSmart` process and widget extension but contains no request bodies or API schema.
- The IP-based HTTP endpoint seen in the capture is still reachable, but app 1.12 uses the
  HTTPS hostname `tayo.zontesmotor.com` for its newer REST constants. Smart Auto uses the
  live HTTPS web-account flow above and does not embed the captured Basic authorization
  value or Mapbox token.
- Carbit and Mapbox requests in the captures serve projection/navigation and map rendering;
  they are not required for account login or the vehicle image.

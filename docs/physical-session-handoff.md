# Synthetic physical-session handoff

`DEVELOPMENT_ONLY_PHYSICAL_SESSION_APPROVAL` is disabled by default and cannot
be enabled for release builds. The mobile approval UI accepts only a short user
code. It reads the claim session only from RAM, sends it once to the generated
approval route over the authenticated client, then clears its controller and
session reference. It never displays a device code, session value, or response
body.

The paired operator utility performs the synthetic-only start, polling, and
redemption flow. It keeps the device code and redeemed bundle in memory and
forwards the bundle directly to the installer seam. Live HTTP, COM16, BLE, and
Wi-Fi execution remain blocked pending a separately approved physical preflight.

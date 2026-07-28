# Mobile BLE provisioning wire contract

`MOBILE_BLE_PROVISIONING_WIRE_CONTRACT_READY`

The firmware parser is authoritative. The mobile client sends one deterministic
UTF-8 JSON object with exactly these fields: `schema`, `schemaVersion`,
`sessionId`, `deviceId`, `sessionToken`, `ssid`, and `password`. The required
schema is `urn:algaguard:schema:onboarding:ble-provisioning-request:v1`; the
supported schema version is `1.0.0`. Unknown fields, aliases, missing fields,
and duplicate fields are rejected by firmware.

The provisioning service is `0000a1a0-0000-1000-8000-00805f9b34fb`. Requests
are written with response only to `0000a1a1-0000-1000-8000-00805f9b34fb`.
Safe status is read and subscribed only on
`0000a1a2-0000-1000-8000-00805f9b34fb`.

Each request is framed big-endian as protocol version (1 byte), message ID
(4 bytes), fragment index (2 bytes), fragment count (2 bytes), and payload
length (2 bytes). The header is 11 bytes, fragment payloads are at most 256
bytes, frames at most 267 bytes, and an assembled payload at most 1024 bytes.
The client waits for each write response and treats `ACCEPTED` only from the
safe status characteristic as success.

Payloads, frames, passwords, and session tokens are never logged or shown in
the UI. The remaining blocker is a safe ephemeral-session handoff from
`/claims/consume` to the COM16 installer; that work belongs to Micro-Sprint
14C2B2B.

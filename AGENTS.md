# Repository working rules

- Use Flutter, Dart, Riverpod, Dio, secure storage, QR scanning, BLE provisioning, and native WebSocket recovery.
- Store user tokens only in secure storage. Never persist or log Wi-Fi passwords, claim codes, or device credentials.
- HTTPS remains authoritative and carries claims/commands. WebSocket is live updates only.
- Keep Android permissions minimal and preserve iOS-compatible service abstractions.
- Do not claim real BLE, QR camera, or device success without hardware evidence.

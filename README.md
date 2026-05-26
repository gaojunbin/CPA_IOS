# CPA Panel iOS

SwiftUI iOS client for CLIProxyAPI management endpoints.

## Backend Requirements

- CLIProxyAPI management routes must be enabled.
- Remote access must be allowed when connecting from iPhone:
  - `remote-management.allow-remote: true`
  - `remote-management.secret-key` configured, or `MANAGEMENT_PASSWORD` set
- The app sends `Authorization: Bearer <management-key>`.
- Use HTTPS for internet-facing servers. HTTP is intended for localhost/LAN testing only.

The app accepts either a server origin such as `https://cpa.example.com` or a copied panel URL such as `https://cpa.example.com/management.html#/quota`.

## Open

Open `CPA-IOS.xcodeproj` in Xcode, select the `CPA-IOS` target, set a signing team, then run on simulator or device.

The app stores the management key in Keychain and keeps the server URL in `UserDefaults`.

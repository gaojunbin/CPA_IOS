# CPA Panel Privacy Policy

Last updated: May 30, 2026

CPA Panel is an iOS client for monitoring a user-provided CLIProxyAPI management endpoint. The app is designed to keep monitoring data on the device unless the user connects to their own server.

## Data Collection

The bundled app code does not collect analytics, advertising identifiers, crash reports, contacts, location, photos, camera data, microphone data, health data, financial data, or other personal data for the developer.

The app does not track users across apps or websites.

## Local Data Storage

CPA Panel stores the configured server URL, refresh interval, and local alert settings in `UserDefaults`.

The management key is stored in the iOS Keychain. It is used only to authenticate requests to the CLIProxyAPI server configured by the user.

The built-in demo dashboard is generated locally and does not save a server URL, management key, or account credential.

## Network Requests

CPA Panel sends the configured management key only to the user-provided CLIProxyAPI server using an Authorization header.

Management API responses are displayed in the app and are not intentionally persisted by URLSession. The app uses an ephemeral network session with persistent URL cache and cookie storage disabled.

CLIProxyAPI may proxy upstream quota requests on behalf of the user's own server configuration. CPA Panel does not receive raw upstream account tokens from CLIProxyAPI.

## Notifications

Low-quota alerts are optional local notifications generated on the device after a dashboard refresh. When low-quota alerts are enabled, the app may use iOS Background App Refresh to opportunistically refresh quota and generate local alerts. iOS controls the exact timing. The app does not register for remote push notifications.

Notification text hides account names and server names by default. Users can opt in to detailed notification text in Settings.

Tapping a low-quota notification opens the app to the dashboard. This behavior is local to the device and does not use remote push notifications.

## User Control

Users can clear the saved connection in Settings. This removes the saved server URL, refresh settings, local alert settings, and Keychain management key from the device.

Users can copy a support diagnostics report from Settings. The report can include generation time, app version, connection status, server URL, refresh interval, alert settings, notification authorization, alert presentation, badge availability, and Background App Refresh status. It does not include the management key value.

Management key entry fields, dashboard server hosts, dashboard account identifiers, project IDs, and account-detail identifiers are marked privacy-sensitive in SwiftUI redaction contexts.

If analytics, crash reporting, hosted telemetry, or additional data collection are added in a future release, this policy and the app privacy manifest must be updated before release.

## Contact

Use the support URL provided in App Store Connect for privacy or support questions.

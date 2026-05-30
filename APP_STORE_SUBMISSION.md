# CPA Panel iOS App Store Notes

Use this as a submission checklist after opening `CPA-IOS.xcodeproj` on a Mac with full Xcode.
Use `APP_STORE_METADATA.md` as the copy source for App Store Connect text fields and screenshot planning.
Publish `SUPPORT.md` and `PRIVACY_POLICY.md` to public HTTPS URLs before filling the App Store Connect support and privacy policy URL fields.

## App Information

- Name: CPA Panel
- Subtitle: CLIProxyAPI quota monitor
- Category: Developer Tools or Utilities
- Primary language: Chinese Simplified
- Sign-in: No third-party account sign-in. The user connects to their own CLIProxyAPI management endpoint with a management key.

## Review Notes

CPA Panel is a client for self-hosted CLIProxyAPI instances. Review can start with the built-in demo dashboard from the first screen, and the same demo can be reopened from Settings after a connection is saved; no credentials are saved in demo mode. The demo includes Codex, Claude, Antigravity, Kimi, Grok, a disabled Gemini account, and bundled account-detail model metadata with runtime badges so the main quota/status UI is visible without credentials. To review live networking, Apple needs a reachable CLIProxyAPI server URL and management key. The app can also be reviewed against a local network server if the reviewer device is on the same network.

Suggested review note:

```text
CPA Panel connects to a user-provided CLIProxyAPI management endpoint and displays account status, quota windows, model runtime status badges, recent request activity, and API key usage. No account is created in the app. A built-in demo dashboard is available on the first screen for UI review without credentials. Please use the provided demo server URL and management key to test live networking.
```

## Privacy Answers

- Tracking: No.
- Data linked to user: None collected by the bundled app code.
- Data not linked to user: None collected by the bundled app code.
- Local storage: The app stores the server URL and refresh interval in UserDefaults and the management key in Keychain on the device.
- Demo mode: The bundled demo dashboard and account-detail model metadata are generated locally; demo mode does not store credentials.
- Network: The app sends the configured management key only to the user-provided CLIProxyAPI server using an Authorization header.
- Network caching: Management requests use an ephemeral URLSession with persistent URL cache and cookie storage disabled, and include no-store cache headers.
- API key usage: The management API may return API key usage counters keyed by raw API keys. CPA Panel displays masked key text only and uses stable hashed row identifiers instead of raw key strings.
- Sensitive UI fields: Management key entry fields, dashboard server hosts, dashboard account identifiers, project IDs, API base URLs, and account-detail identifiers are marked privacy-sensitive in SwiftUI for system redaction contexts.
- Notifications: Optional low-quota alerts are local notifications generated on device after refresh; the first connection setup keeps alerts off and alerts must be enabled from Settings after notification permission is granted. The app does not use remote push notifications.
- Notification privacy: Notification text hides account and server identifiers by default. Users can opt in to detailed notification text from Settings; turning low-quota alerts off also turns detailed notification text off.
- Notification tap behavior: Tapping a low-quota local notification opens the attention-only dashboard view.
- Background App Refresh: When low-quota alerts are enabled for a saved connection, the app registers a `BGAppRefreshTask` to opportunistically refresh live quota and generate local alerts. iOS controls task timing; the app does not run continuous background monitoring and does not use remote push.
- Support diagnostics: Settings can copy a diagnostics report for support. It includes generation time, app/connection settings, and Background App Refresh status, and explicitly does not include the management key value.
- Notification diagnostics: The same report includes notification authorization, alert presentation, and badge availability so local alert issues can be diagnosed without credentials.
- Notification permission denial: If permission is denied while saving Settings, the verified connection and refresh settings remain saved, but low-quota alerts stay disabled until permission is granted.
- Notification alert setting: If notification banners/alerts are disabled in iOS Settings, CPA Panel treats low-quota alerts as unavailable even when general notification authorization remains granted.
- Notification recovery: The Settings recovery button opens the app notification settings page on supported iOS versions, with the app settings page as a fallback.
- Badge: When low-quota alerts are enabled, notification permission is available, notification banners/alerts are enabled, and the app badge setting is enabled, the app may update the local app icon badge after foreground refresh to show the number of accounts that need attention. If permission is denied or revoked, or notification banners/alerts are disabled, alerts are disabled on the next app launch, foreground resume, or Settings open; the badge and pending CPA local alerts are cleared. If only app badge permission is disabled, local alerts remain available but badge counts are cleared and omitted. This badge is not driven by remote push.
- Alert repeat behavior: The app throttles unchanged local alerts to avoid repeated banners, but resets that throttle after all attention candidates clear or the saved server/key/alert settings change so a later relevant alert can notify again.
- Launch screen: `UILaunchScreen` uses the asset-catalog `LaunchBackground` named color, including a dark appearance, so the system launch view matches the app background without custom launch artwork.
- Transport: Internet-facing servers must use HTTPS. Plain HTTP is limited to localhost/private/LAN-style endpoints for self-hosted testing.

Keep App Store Connect answers aligned with the actual demo server and distribution plan. If analytics, crash reporting, or hosted telemetry are added later, update `App/PrivacyInfo.xcprivacy` and App Store Connect before submission.

## Reviewer Smoke Test

- Open the built-in demo dashboard first to inspect the main account, quota, model runtime badge, and status views without credentials.
- After saving a connection, open Settings and use the demo action to confirm demo mode remains available without clearing credentials.
- Connect to the provided CLIProxyAPI test server and refresh the dashboard once to verify live quota, account detail, and API key usage.
- Enable low-quota alerts in Settings while keeping account-name notification text off, then refresh an account set that includes a low, cooling, or failing account.
- Confirm Settings shows notification delivery or badge availability before copying diagnostics.
- Confirm Background App Refresh is enabled for CPA Panel on the review device; background refresh scheduling is opportunistic and should be treated as a supplemental local-alert path, not the deterministic smoke-test path.
- Confirm the foreground notification uses generic text and a `本地提醒` subtitle unless detailed notification text is explicitly enabled.
- Tap the local notification and confirm CPA Panel opens the attention-only dashboard list.
- Confirm the local app icon badge matches the number of accounts that need attention, then disable low-quota alerts and confirm the badge plus pending CPA alert notifications clear.
- If notification permission is denied, use the Settings recovery button to open the app notification settings and confirm the badge clears.

## Export Compliance

`ITSAppUsesNonExemptEncryption` is set to `false` because the app uses platform networking/security APIs and does not ship custom non-exempt encryption.

## Final Xcode Gates

Run these on a machine with full Xcode before upload:

```sh
DEVELOPMENT_TEAM=YOURTEAMID Scripts/validate_xcode_release.sh
```

The script runs `Scripts/validate_local.sh`, verifies iPhone simulator and iPhoneOS SDK availability, builds the simulator target, requires a signing team for archive creation, removes any stale archive at `CPA_ARCHIVE_PATH`, and verifies the Release `.xcarchive` directory was created. Set `CPA_PRODUCT_BUNDLE_IDENTIFIER` if the App Store Connect app record uses a different bundle identifier. Set `CPA_ALLOW_PROVISIONING_UPDATES=1` if the release machine should let automatic signing create or update provisioning profiles. Then validate the archive in Xcode Organizer, confirm the generated privacy report, and test the app on at least one physical iPhone against a real CLIProxyAPI server.

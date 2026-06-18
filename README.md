# CPA Panel iOS

SwiftUI iOS client for monitoring CLIProxyAPI account status and live quota.

The app mirrors the CPA macOS status bar workflow on iPhone/iPad:

- Connect to one or more CLIProxyAPI services, each with its own management URL and key, and switch between them instantly from the dashboard title's dropdown (see Multiple Services).
- Preview the finished dashboard with bundled demo data before saving any credentials, or reopen the demo from Settings later.
- Demo mode covers Codex, Claude, Antigravity, Kimi, Grok, and a disabled Gemini account.
- Demo account detail includes bundled model metadata and runtime badges, so review can inspect model status without a live server.
- Show Codex 5h/7d remaining-quota averages as the headline metric, scoped to Codex accounts only, with a caption clarifying that other providers report their own quota shapes per card.
- Pin low-quota, cooling, and error accounts near the top of the dashboard.
- Use one configurable attention threshold for optional low-quota local alerts.
- Sort local alert candidates with that same threshold.
- Fetch per-account quota windows through `/v0/management/api-call`.
- Refresh one account directly from its detail screen and see when live quota was last synced.
- Apply account detail refresh results back to the dashboard list immediately.
- Load account-detail live quota and model metadata independently so slow quota providers do not block model status visibility.
- Group accounts by provider, matching the macOS status popover structure.
- Load the account list first, then sync live quota progressively with bounded concurrency.
- Keep the last live quota visible while a new refresh is syncing.
- Keep existing dashboard data when only refresh or alert settings change.
- Show quota reset timing directly in account rows when the upstream provider returns it.
- Display reset countdowns and provider quota windows with localized Chinese timing text.
- Show provider-level 5h/7d averages and lowest remaining quota in each provider section header.
- Render each channel's quota from the live web payload instead of hard-coded fields, so Codex shows 5h/7d windows, Grok shows credit balance, Antigravity shows per-model quota, and so on.
- Coalesce refresh triggers so manual refresh, foreground resume, and timer refresh do not stack duplicate sync jobs.
- Show compact localized connection and network errors for unreachable servers.
- Surface provider runtime status, model cooldowns, recent request activity, and account metadata in account detail.
- Mark available models with runtime status badges in account detail, with abnormal or limited models sorted first.
- Treat account-level backend `last_error` values as attention-worthy runtime errors.
- Mark management keys, server hosts, dashboard account identifiers, project IDs, and account-detail identifiers as privacy-sensitive in SwiftUI.
- Copy a support diagnostics report from Settings without including the management key.
- Show notification delivery and badge availability in Settings and support diagnostics.
- Show backend refresh schedule and Codex subscription dates in account detail when CLIProxyAPI returns them.
- Auto-refresh in the foreground with a configurable interval.
- Optionally send local notifications when refreshed accounts are low, cooling, or failing.
- When low-quota alerts are enabled, register Background App Refresh so iOS can opportunistically refresh quota and generate local alerts while the app is not foregrounded.
- Open the dashboard when a low-quota local notification is tapped.

## Multiple Services

The app can monitor multiple CLIProxyAPI services ("号池" / pools) and switch between them instantly. Services are fully independent and never share data.

- The dashboard title is a dropdown switcher: tap the current service name to pick another service, or open **管理服务 (Manage services)**.
- Add, edit, reorder, and delete services in **服务与设置 (Settings)**. Each service keeps its own server URL, management key, refresh interval, and low-quota alert settings.
- Each service's management key is stored separately in the Keychain, keyed per service.
- Switching shows the selected service's last-loaded data instantly, then refreshes live in the background.
- Low-quota background alerts and the app icon badge track the currently selected service only; switching resets the local alert throttle so the new service starts clean.
- Upgrading from a single-connection build automatically migrates your existing connection into the first service.

## Backend Requirements

- CLIProxyAPI management routes must be enabled.
- Remote access must be allowed when connecting from iPhone:
  - `remote-management.allow-remote: true`
  - `remote-management.secret-key` configured, or `MANAGEMENT_PASSWORD` set
- The app sends `Authorization: Bearer <management-key>`.
- Management requests use an ephemeral URLSession with no persistent URL cache or cookie storage, plus explicit no-store request headers.
- Live quota requires `/v0/management/api-call`. Supported quota providers currently follow the macOS client: Codex/OpenAI WHAM, Claude, Antigravity, Kimi, and xAI/Grok.
- Use HTTPS for internet-facing servers. The app rejects public `http://` URLs; HTTP is accepted only for localhost, private IP, link-local, single-label LAN names, and `.local`/`.lan`/`.home.arpa` LAN endpoints.

The app accepts a server origin such as `https://cpa.example.com`, a copied panel URL such as `https://cpa.example.com/management.html#/quota`, or a copied management API URL such as `https://cpa.example.com/v0/management/auth-files`.

## Open

Open `CPA-IOS.xcodeproj` in Xcode, select the `CPA-IOS` target, set a signing team, then run on simulator or device.

The app stores each service's management key in Keychain (keyed per service) and keeps the service list and current selection in `UserDefaults`.
The demo dashboard is non-persistent, can be opened from first setup or Settings, and does not save a server URL or management key.
Low-quota notifications are local device notifications and are only enabled after the user grants notification permission in Settings.
The first connection setup does not inherit stale alert defaults; low-quota alerts must be enabled from Settings after a connection exists.
Background App Refresh is scheduled only while a saved connection has low-quota alerts enabled. iOS controls exact timing, so foreground refresh remains the deterministic update path.
Settings shows the current local notification delivery state and the iOS Background App Refresh status when low-quota alerts are enabled, and diagnostics include notification authorization, alert presentation, badge availability, and Background App Refresh status for support.
Notification banners hide account names and server names by default; users can opt in to detailed notification text. Turning low-quota alerts off also turns detailed notification text off.
Tapping a low-quota notification opens CPA Panel to the dashboard.
If notification permission is denied while saving Settings, the app keeps the verified connection and refresh settings but leaves low-quota notifications disabled.
If the user turns off notification banners/alerts in iOS Settings, CPA Panel treats low-quota alerts as unavailable even if the app still has general notification authorization.
The notification recovery button opens the iOS notification settings page when available, with the app settings page as a fallback.
When low-quota notifications are enabled and notification permission is available, foreground refreshes also update the local app icon badge to the current number of accounts that need attention if the app badge setting is enabled. Disabling alerts, clearing all candidates, removing the connection, or revoking notification permission clears the local badge and pending CPA alert notifications.
If notification alerts remain allowed but the app badge setting is disabled, CPA Panel keeps local alerts available but clears and omits badge counts on launch, foreground resume, and Settings open.
If notification permission is revoked outside the app, CPA Panel turns low-quota alerts off the next time the app launches, returns to the foreground, or opens Settings.
When all attention candidates clear, or when the saved server/key/alert settings change, the app also resets its local alert throttle so later relevant alerts are not suppressed as duplicates from an older monitoring scope.

## Release Checklist

Before App Store submission on a machine with full Xcode:

- Set `DEVELOPMENT_TEAM` and confirm `PRODUCT_BUNDLE_IDENTIFIER`.
- Run `Scripts/validate_xcode_release.sh` to execute the local checks, simulator build, and Release archive gate.
- Build and run the `CPA-IOS` target on a physical device.
- Test first connection, foreground refresh, pull-to-refresh, and account detail live quota refresh against a real CLIProxyAPI server.
- Enable low-quota alerts and Background App Refresh on a physical device, then confirm the background refresh task can schedule local low-quota alerts.
- Validate the generated archive in Xcode Organizer.
- Review the generated privacy report and App Store Connect privacy answers against the actual distribution model.

See `APP_STORE_SUBMISSION.md` for review notes, privacy-answer guidance, and final Xcode gates.
Use `APP_STORE_METADATA.md` as the App Store Connect copy source for the app description, keywords, review note, privacy answers, and screenshot checklist.
Use `SUPPORT.md` and `PRIVACY_POLICY.md` as the source text for public support and privacy policy URLs.

## App Store Metadata

- `App/PrivacyInfo.xcprivacy` declares no tracking and no collected data types for the bundled app code.
- The privacy manifest includes the required reason API declaration for `UserDefaults` because the app stores the configured server URL and refresh interval locally.
- Management responses are not intentionally persisted by URLSession; the default client session is ephemeral and cache-bypassing.
- `NSLocalNetworkUsageDescription` is present for LAN/self-hosted CLIProxyAPI endpoints.
- Low-quota alerts use local notifications only; the app does not register for remote push notifications.
- `BGTaskSchedulerPermittedIdentifiers` and `UIBackgroundModes` declare the local Background App Refresh task used only for optional low-quota alert refreshes.
- Notification text hides account and server identifiers by default and only shows details when the user enables that setting.
- Tapping a low-quota local notification opens the dashboard.
- The app icon badge is local and reflects the latest foreground refresh when the app badge setting is enabled; it is cleared, along with pending CPA alert notifications, when low-quota alerts are disabled, notification permission is unavailable, notification banners/alerts are disabled, or no saved connection is active.
- If only app badge permission is disabled, notification alerts remain available but badge counts are cleared and omitted.
- The launch screen uses the `LaunchBackground` named color from the asset catalog, with light and dark variants, so startup matches the app background before SwiftUI renders.
- Management key entry fields, dashboard server hosts, dashboard account identifiers, project IDs, and account-detail identifiers use SwiftUI privacy-sensitive annotations for system redaction contexts.
- Settings can copy a diagnostics report for support; it records the generation time, whether a management key exists, and the current Background App Refresh status, but never includes the key value.
- Diagnostics also record notification authorization, alert presentation, and badge availability so local alert failures can be debugged without exposing credentials.
- `ITSAppUsesNonExemptEncryption` is set to `false`; the app uses platform networking/security APIs and does not ship custom non-exempt encryption.

## Local Validation

This repository includes a Swift package validation target for the shared client/parser layer:

```sh
Scripts/validate_local.sh
```

The script runs the CLT-compatible checks below:

```sh
swift build
swift run CPAKitValidation
swiftc -swift-version 6 -typecheck -parse-as-library App/*.swift Sources/CPAKit/*.swift
swiftc -typecheck -parse-as-library App/*.swift Sources/CPAKit/*.swift
bash -n Scripts/validate_local.sh Scripts/validate_xcode_release.sh
git diff --check
plutil -lint App/Info.plist App/PrivacyInfo.xcprivacy CPA-IOS.xcodeproj/project.pbxproj
xmllint --noout CPA-IOS.xcodeproj/xcshareddata/xcschemes/CPA-IOS.xcscheme
find App/Assets.xcassets -name Contents.json -print0 | xargs -0 jq empty
```

This machine only has Apple Command Line Tools, so simulator/device builds still need full Xcode. `swift test` is not part of the local gate because this CLT environment does not include `XCTest` or Swift `Testing`; `CPAKitValidation` is the package validation entry point here.

On a full Xcode machine, run the App Store build gates with:

```sh
DEVELOPMENT_TEAM=YOURTEAMID Scripts/validate_xcode_release.sh
```

The release script requires a signing team before creating the Release archive, removes any stale archive at `CPA_ARCHIVE_PATH`, and verifies the `.xcarchive` directory was created. Set `CPA_PRODUCT_BUNDLE_IDENTIFIER` if you need to override the checked-in bundle identifier for a specific App Store Connect app record. Set `CPA_ALLOW_PROVISIONING_UPDATES=1` if the Xcode machine should let automatic signing create or update provisioning profiles.

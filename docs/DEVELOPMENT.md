# Development and distribution

[Project overview](../README.md) · [Feature and integration reference](REFERENCE.md)

Read [AGENTS.md](../AGENTS.md) for contributor rules and the code map, and [CPA_SYNC.md](../CPA_SYNC.md) for the audited upstream revision and compatibility evidence. All commands below run from the repository root.

## Install from source

Use a Mac with full Xcode and the iOS SDK installed.

```sh
open CPA-IOS.xcodeproj
```

Open `CPA-IOS.xcodeproj` in Xcode, select the `CPA-IOS` target, set a signing team, then run on simulator or device.

The target requires iOS 16 or later. On first launch, connect to your server or open the bundled demo without saving credentials. See [backend requirements](REFERENCE.md#backend-requirements) for remote access setup.

For screenshots and UI checks, launch with `-cpa-demo` to use non-persistent sample data. Never capture real account identifiers, server addresses, or credentials for public documentation.

## Local Validation

This repository includes a Swift package validation target for the shared client/parser layer:

```sh
Scripts/validate_local.sh
```

The script runs the CLT-compatible checks below:

```sh
swift build --scratch-path /tmp/cpa-ios-validation
swift run --scratch-path /tmp/cpa-ios-validation CPAKitValidation
swiftc -swift-version 6 -typecheck -parse-as-library App/*.swift Sources/CPAKit/*.swift
swiftc -typecheck -parse-as-library App/*.swift Sources/CPAKit/*.swift
bash -n Scripts/validate_local.sh Scripts/validate_xcode_release.sh
git diff --check
plutil -lint App/Info.plist App/PrivacyInfo.xcprivacy CPA-IOS.xcodeproj/project.pbxproj
xmllint --noout CPA-IOS.xcodeproj/xcshareddata/xcschemes/CPA-IOS.xcscheme
find App/Assets.xcassets -name Contents.json -print0 | xargs -0 jq empty
```

The shared package checks can run with Apple Command Line Tools; simulator/device builds require full Xcode. `CPAKitValidation` is the package validation entry point, so the local gate does not depend on XCTest or Swift Testing.

On a full Xcode machine, run the App Store build gates with:

```sh
DEVELOPMENT_TEAM=YOURTEAMID Scripts/validate_xcode_release.sh
```

The release script requires a signing team before creating the Release archive, removes any stale archive at `CPA_ARCHIVE_PATH`, and verifies the `.xcarchive` directory was created. Set `CPA_PRODUCT_BUNDLE_IDENTIFIER` if you need to override the checked-in bundle identifier for a specific App Store Connect app record. Set `CPA_ALLOW_PROVISIONING_UPDATES=1` if the Xcode machine should let automatic signing create or update provisioning profiles.

## Release Checklist

Before App Store submission on a machine with full Xcode:

- Set `DEVELOPMENT_TEAM` and confirm `PRODUCT_BUNDLE_IDENTIFIER`.
- Run `Scripts/validate_xcode_release.sh` to execute the local checks, simulator build, and Release archive gate.
- Build and run the `CPA-IOS` target on a physical device.
- Test first connection, foreground refresh, pull-to-refresh, and account detail live quota refresh against a real CLIProxyAPI server.
- Enable low-quota alerts and Background App Refresh on a physical device, then confirm the background refresh task can schedule local low-quota alerts.
- Validate the generated archive in Xcode Organizer.
- Review the generated privacy report and App Store Connect privacy answers against the actual distribution model.

See [APP_STORE_SUBMISSION.md](../APP_STORE_SUBMISSION.md) for review notes, privacy-answer guidance, and final Xcode gates.
Use [APP_STORE_METADATA.md](../APP_STORE_METADATA.md) as the App Store Connect copy source for the app description, keywords, review note, privacy answers, and screenshot checklist.
Use [SUPPORT.md](../SUPPORT.md) and [PRIVACY_POLICY.md](../PRIVACY_POLICY.md) as the source text for public support and privacy policy URLs.

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

## App icon

The monochrome Confluence mark represents multiple upstream channels converging into one managed endpoint. The artwork uses pure black and white, a consistent rounded stroke, and a generous safe area. The editable SVG is the only drawing source; platform exports are rendered directly at each required size.

Regenerate the checked-in icon assets from this repository:

```sh
swift Scripts/generate_app_icon.swift
```

The iOS master is `App/Assets.xcassets/AppIcon.appiconset/AppIcon-iOS.svg`. The script reads `Contents.json` and exports every PNG slot as opaque RGB; iOS applies the corner mask.

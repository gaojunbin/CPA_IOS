# CPA iOS agent instructions

Native SwiftUI client (iOS 16+, Swift 6), with a macOS-compatible shared `CPAKit` package for local validation.

## Scope and working rules

- This is a native client for remotely deployed CLIProxyAPI. Do not add Docker or embed the proxy server.
- Treat `../CLIProxyAPI` as a read-only upstream reference: do not edit, fetch, pull, checkout, or build into that directory during client compatibility work.
- Compatibility sync includes current upstream built-in provider additions, their account/model information, and native authorization flows. Keep quota semantics aligned with upstream; do not invent availability or expand into unrelated plugin/Home administration.
- Communicate with the user in Chinese. Write code, comments, documentation, branches, and commit messages in English. Preserve the existing Chinese product UI.
- Keep functions focused and use the existing directory structure. Do not introduce version-suffixed replacements or commented-out code.
- Keep temporary scripts, build output, and logs under `/tmp`; do not commit one-off validation scripts.
- Preserve service profiles, per-service Keychain isolation, and existing settings. Edit symlinked configuration files in place.
- Management credentials and downloaded auth JSON must never appear in logs, fixtures, docs, or persisted snapshots. Use synthetic credentials for tests.

## Compatibility workflow

1. Read [CPA_SYNC.md](CPA_SYNC.md) for the last synced CLIProxyAPI and management web UI commits, then diff both upstream repositories from there.
2. Inspect all working trees before changes. Compare the recorded upstream commit with the local upstream HEAD; do not assume the cloud deployment runs either version.
3. Check existing endpoints against upstream `internal/api/server_management_v8.go`, `internal/api/server_management.go`, `docs/management-api-v8.md`, and `internal/api/handlers/management/`. Check config model resolution against `sdk/cliproxy/service_models.go` and field names against `internal/config/` and `internal/registry/`. Compare live quota request contracts with the current management web UI (`router-for-me/Cli-Proxy-API-Management-Center`).
4. Operational endpoints use `/v8/management` (credentials, credential models/download/refresh, `requests/api-call`, OAuth, routing model definitions); servers before v8.0.0 are unsupported. Config reads (`*-api-key`, `openai-compatibility`, `oauth-model-alias`, `oauth-excluded-models`, `routing/strategy`, `force-model-prefix`) and client `api-keys` management stay on the deprecated-but-served `/v0/management` until the grouped v8 config tree is adopted. Preserve `Authorization: Bearer <management-key>`, `auth_index`, and server-side `$TOKEN$` substitution. The `api-call` request `data` and response `body` fields are JSON strings; the upstream HTTP status is nested in `status_code`.
5. Keep config model aliases, duplicate upstream routing targets, wildcard exclusions, prefix policy, display names, and capability metadata aligned. Fully excluded explicit models must stay empty, without falling back to defaults. Base-URL-only credentials remain valid.
6. Missing model runtime state is unknown. Current `quota`/`model_quotas` observations are not cooldown state. Neither model registration nor account `status: active` proves live quota availability. Low quota alone is not a connection-health failure.
7. Fix the corresponding existing behavior in the sibling client when applicable; preserve platform-specific feature scope.
8. Run relevant regression checks and the native build. After a sync, update only the date, commits, and versions in `CPA_SYNC.md` of both clients; keep change details and validation evidence in commit messages and release notes.

## Code map

- `Sources/CPAKit/CPAClient.swift`: management transport and live quota requests.
- `CPAClientRouting.swift`, `CPAClientAPIKeys.swift`: existing model/routing reads and API key operations.
- `CPAModels.swift`, `CPAUsageParser.swift`, `CPADashboardMetrics.swift`: decoding, quota interpretation, and health summaries.
- `CPAConfigChannels.swift`, `ConfiguredModelMetadata.swift`, `CPARoutingModels.swift`: config model metadata and routing resolution.
- `App/`: SwiftUI screens, per-service connection storage, dashboard refresh, and local alert/background refresh handling.
- `Validation/`: persistent package validation, including `UpstreamCompatibility.swift` regression fixtures.
- `CPA-IOS.xcodeproj/project.pbxproj`: explicit file membership. Any new app/shared source must be added to both the file group and Sources build phase; a Swift package build alone does not validate this.

## Build and verify

Run from this repository. The installed full Xcode used for the current audit is `/Applications/Xcode-beta.app`; recheck the installation and simulator destinations when needed.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/validate_local.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project CPA-IOS.xcodeproj -scheme CPA-IOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/cpa-ios-xcode CODE_SIGNING_ALLOWED=NO build
```

For core-only iteration with all build output outside the repository:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run --scratch-path /tmp/cpa-ios-validation CPAKitValidation
```

To run interactively:

```sh
open CPA-IOS.xcodeproj
```

Choose `CPA-IOS` and an iPhone simulator, then Run. Use bundled demo mode without credentials, or enter the server URL and management key to inspect a real service. `-cpa-demo` opens the non-persistent demo for UI checks. `Scripts/validate_xcode_release.sh` is a separate signed archive gate. A simulator build does not verify physical-device alerts, cloud access, signing, TestFlight, or App Store distribution.

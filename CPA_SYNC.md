# CLIProxyAPI compatibility sync

## Baseline

| Item | Audited value |
| --- | --- |
| Audit date | 2026-09-21 |
| Upstream repository | https://github.com/router-for-me/CLIProxyAPI |
| Local reference | `../CLIProxyAPI` |
| Upstream tag | `v7.3.11` |
| Upstream full commit | `ffe6ad3c5fcf0a5eedd2198cd2e04b0249dc5063` |
| Upstream commit date | `2026-09-21T22:38:13+08:00` |
| Previous audited upstream | `v7.3.10`, `a5ab69521f7b4e0f244836d0419da8fcd89408ea` |
| Cloud deployment version | Not inspected |
| Scope | Current built-in providers, native authorization, quota, models, and existing management features |

The user requested current provider support as well as existing-feature compatibility. The clean upstream branch was fast-forwarded to the revision above and then treated as a read-only reference. No upstream source or deployed proxy was changed.

## Provider adaptation

- Both native clients recognize Devin, Meta, and Kimi.ai as distinct providers and expose their authorization flows. Devin uses an authorization-code flow with a server-configured loopback port. Meta and Kimi.ai use device authorization, including user-code and expiry metadata.
- Preserve the complete Devin callback URL, validate its session state, poll until persistence succeeds, and cancel abandoned server sessions. A successful callback submission alone is not login success.
- Refresh exactly one Devin account with `POST /v0/management/auth-files/refresh`, providing `name` and `auth_index`. Decode only `ok` and `auth.quota`; credential metadata from the response is never retained in a snapshot.
- Display Devin plan and daily/weekly remaining percentages, reset times, server observation time, and provider-pool averages. Keep zero distinct from unknown; reject invalid percentages and discard windows whose reset time has passed. A missing timestamp stays visibly unknown. Refresh failures remain errors while preserving the previous dated observation.
- Keep passive quota observations separate from scheduler `cooldowns`. Neither zero remaining quota nor a model registration invents an account-wide cooldown or proves live model availability.
- Kimi.ai quota uses `https://api.kimi.ai/coding/v1/usages`; Kimi coding retains `https://api.kimi.com/coding/v1/usages`. This follows the shared coding API and upstream domain split; live Kimi.ai responses remain unverified.
- Meta account/model support does not claim an undocumented built-in quota endpoint. Add Meta and Grok API-key config channels to model/routing inventory, preserving aliases, duplicate routing targets, prefix policy, wildcard exclusions, and capability metadata.

## Contract references and preserved behavior

- OAuth: `internal/api/server_management.go`, `auth_files_devin_oauth.go`, `auth_files_provider_oauth.go`, and `docs/management-devin-oauth.md`.
- Devin quota: `internal/auth/devin/record.go`, `internal/runtime/executor/devin_executor.go`, and `auth_files_refresh.go`. `/quota/fetch` is a plugin/probe interface, not the built-in Devin refresh contract.
- Models: `sdk/cliproxy/service_models.go`, registry definitions, and the existing `auth-files/models` endpoint. Model queries continue using account IDs to disambiguate shared filenames.
- Management bearer authentication, server-side `$TOKEN$` substitution, string `api-call.data`/`body`, nested upstream `status_code`, API key operations, and per-service settings/Keychain isolation remain intact.
- The v7.3.10-to-v7.3.11 changes affect runtime translation, response streaming, schema normalization, and plugin usage metadata; the audited native management contracts remain unchanged.
- No plugin/Home administration or quota-reset controls were added. Live provider APIs, production credentials, cloud changes, and device acceptance are separate from fixture validation.

## iOS delivery and validation

- Client starting commit: `8e79a4a64acbc7b6ac4c77804ce26731ad2cff37`.
- Add a native account-authorization sheet from the dashboard menu, with browser links, device codes, callback submission, polling, timeout, cancellation, and refresh after success.
- New shared sources and the authorization screen are registered in the Xcode file group and Sources build phase.
- Validation commands (full Xcode):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/validate_local.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project CPA-IOS.xcodeproj -scheme CPA-IOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/cpa-ios-xcode CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-disable-sandbox' build
git diff --check
```

- `Scripts/validate_local.sh` passed: package build/regressions, Swift 6/default typechecks, shell syntax, whitespace, plist/project, scheme XML, and asset JSON checks. Regression coverage includes safe Devin refresh and observations, callback binding, polling/cancellation, Kimi.ai host selection, Meta/Grok config models, and existing client behavior.
- Restricted-environment validation used temporary Swift wrappers with SwiftPM `--disable-sandbox`, caches under `/tmp/cpa-swift-*`, and `swiftc -disable-sandbox -sdk /Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk -target arm64-apple-macosx26.0`. The macOS target is only the host-side app typecheck; the separate Xcode build validates the actual iOS target. Log: `/tmp/cpa-providers-ios-final.log`.
- Native generic iOS Simulator build passed. This environment requires `-disable-sandbox` for the SwiftUI compiler macro process; the outer filesystem restrictions remain enabled. The CoreSimulator service is unavailable, so this is build evidence, not rendered UI or running-device acceptance.
- No live-provider login/quota acceptance, physical-device background/notification checks, signed archive, TestFlight, or App Store submission was performed.

## Next sync

Compare `ffe6ad3c5fcf0a5eedd2198cd2e04b0249dc5063..HEAD` in the upstream reference. Include newly introduced built-in providers in the audit, preserve accurate quota semantics, and validate both native builds. Record live/cloud/distribution acceptance separately.

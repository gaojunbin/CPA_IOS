# CLIProxyAPI compatibility sync

## Baseline

| Item | Audited value |
| --- | --- |
| Audit date | 2026-09-21 |
| Upstream repository | https://github.com/router-for-me/CLIProxyAPI |
| Local reference | `../CLIProxyAPI` |
| Upstream tag | `v7.3.10` |
| Upstream full commit | `a5ab69521f7b4e0f244836d0419da8fcd89408ea` |
| Upstream commit date | `2026-09-21T04:13:44+08:00` |
| Previous audited upstream | `v7.2.155`, `7fac6b15bcfe5ea55c18c9eaec8e5b7e6457d974` |
| Cloud deployment version | Not inspected |
| Scope | Preserve existing native-client features and information |

The user explicitly requested refreshing upstream. Its clean `main` branch was fetched and fast-forwarded to `origin/main` at the revision above, then treated as a read-only reference. No upstream source was edited. This does not upgrade any deployed proxy or prove live provider connectivity.

## Adaptation

- Decode the current `cooldowns` snapshot, including credential/model scope, model key, reason, and fractional RFC3339 retry deadlines. Show current restrictions in existing detail/model views.
- Keep `cooldowns: null` or a missing field unknown. An empty array means no reported retry timers; it does not prove model availability. Ignore expired or malformed retry deadlines, and do not retain synthetic stale model restrictions.
- Keep credential-wide restrictions separate from partial model restrictions. A partial model cooldown does not make the entire account unhealthy. Explicit account failures and disablement still take precedence.
- Keep passive `quota.signals` and `model_quotas` separate from scheduler cooldowns and live provider quota requests.
- Preserve existing model aliases, duplicate upstream routes, exclusions, prefixes, display/capability metadata, and base-URL-only configuration channels.

## Contract audit

| Existing surface | Current result |
| --- | --- |
| Management access | `/v0/management` paths and bearer management authentication remain compatible; reviewed `internal/api/server_management.go` and management handlers. |
| Account list | `auth_files.go` adds `observed_at` and `cooldowns`. Pagination is opt-in via `page`/`page_size`; clients continue requesting the complete list without pagination parameters. Identity remains the backend `id` with `auth_index`. |
| Runtime state | `sdk/cliproxy/auth/cooldown_view.go` defines retry restrictions, not overall availability. The list handler reconciles account status with active credential/model gates. Home/disk-only state can return null cooldowns. |
| Account models | `GetAuthFileModels` still returns registered model IDs and optional display/type/owner metadata. Model lookup uses the backend account ID in `name`; credential-file download uses the filename. Missing runtime status stays unknown. |
| Quota proxy | `api_tools.go` preserves string `data`, nested `status_code`, and string response `body`. `$TOKEN$` remains server-resolved; missing credentials/tokens now fail explicitly with HTTP 400. Existing error handling accepts that failure. |
| Config/model inventory | Existing OpenAI-compatible, Codex, Claude, Gemini, Interactions, and Vertex GET contracts remain compatible. `service_models.go` and config types preserve current alias/exclusion/prefix rules. New internal catalog capabilities do not justify inventing runtime model availability. |
| Routing and API keys | OAuth aliases/exclusions, strategy, force-prefix, file routing metadata, and GET/PATCH/DELETE key contracts remain compatible. No cloud mutations were performed. |
| macOS OAuth | Existing Codex/Claude/Antigravity callback and xAI/Kimi device flows remain supported. `/kimi-auth-url` retains the default Kimi coding flow; the new Kimi.ai route is separate. |

No new Meta, Devin, Kimi.ai, plugin/Home, discovery, quota-reset, or credential-refresh controls were added. Existing provider quota fixtures remain the validation source; live provider APIs and production credentials were not exercised.

## iOS delivery

- Client starting revision: `be0d765002cfdcd4e329be0190c8ddeab70680a0`.
- The shared account model and existing SwiftUI detail/model screens now consume scoped cooldown observations without promoting a partial model restriction into an account-wide failure.
- `AccountCooldown.swift` is included in the Xcode file group and Sources build phase as well as Swift Package Manager.
- Local validation keeps Swift package build output under `/tmp/cpa-ios-validation`.
- GitHub source publication does not establish signing, device installation, TestFlight, or App Store publication; those distribution steps were not performed.

## Validation

Run from `CPA_IOS`:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/validate_local.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project CPA-IOS.xcodeproj -scheme CPA-IOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/cpa-ios-xcode CODE_SIGNING_ALLOWED=NO build
git diff --check
```

- `Scripts/validate_local.sh` passed: package build, `CPAKitValidation`, Swift 6/default typechecks, shell syntax, whitespace, plist/project, scheme XML, and asset JSON checks.
- Runtime regression fixtures cover partial-model versus credential-wide restrictions, unknown/null/empty snapshots, fractional timestamps, expired/invalid dates, passive quota separation, and preserved account health.
- The separate native iOS simulator Debug build passed. Output: `/tmp/cpa-ios-xcode/Build/Products/Debug-iphonesimulator/CPA-IOS.app`.
- No running UI/cloud acceptance, physical-device background/notification tests, signed archive, TestFlight, or App Store submission was performed.

## Next sync

Compare `a5ab69521f7b4e0f244836d0419da8fcd89408ea..HEAD` in the upstream reference. Recheck the sibling macOS behavior and native Xcode source membership, then rerun package and simulator validation. Record actual cloud/device acceptance separately.

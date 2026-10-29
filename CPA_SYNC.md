# CLIProxyAPI compatibility sync

## Baseline

| Item | Audited value |
| --- | --- |
| Audit date | 2026-10-30 |
| Upstream repository | https://github.com/router-for-me/CLIProxyAPI |
| Local reference | `../CLIProxyAPI` |
| Upstream tag | `v8.0.47` |
| Upstream full commit | `90c447d3a8727d115aa7552ec93ce023736ed492` |
| Upstream commit date | `2026-10-29T07:03:21+08:00` |
| Previous audited upstream | `v7.3.11`, `ffe6ad3c5fcf0a5eedd2198cd2e04b0249dc5063` |
| Management web UI reference | `router-for-me/Cli-Proxy-API-Management-Center` `64b4f5aed19b8f791eb21eb9e785ea379ea05b44` (`v1.26.7-3`, 2026-10-26) |
| Cloud deployment version | The two configured deployments reported `v8.0.47` (`90c447d`, built 2026-10-29) and `v8.0.35` (`ae3ee3b`, built 2026-10-19) in unauthenticated management response headers |
| Scope | v8 management API adoption for operational endpoints, quota contracts aligned with the management web UI, and existing management features |

The user asked to pull all three repositories and adapt both native clients to the current gateway, starting from the known missing Antigravity Gemini 5h/weekly quota. The upstream branch was fast-forwarded to the revision above and then treated as a read-only reference. No upstream source or deployed proxy was changed. The macOS client received the same change set; see its `CPA_SYNC.md` for the shared audit details.

## v8.0.47 sync (2026-10-30)

### Upstream delta

- 596 commits since `v7.3.11`. Upstream added a parallel `/v8/management` API (`internal/api/server_management_v8.go`, `docs/management-api-v8.md`, all used routes present since `v8.0.0`) and its `AGENTS.md` now marks `/v0/management` as deprecated and unmaintained. The v0 routes are still registered and the v0 JSON contracts used by this client are unchanged: v8-layout config files are loaded back into the legacy runtime structure, so v0 config GETs keep their keys.
- No new built-in provider. New cooldown reason `transient_rate_limit`. Management responses may be zstd/gzip compressed; URLSession negotiates and decodes them.
- The management web UI moved entirely to `/v8/management` and changed quota request identities: Antigravity Hub user agent (Cloud Code withholds newer models from clients below Hub 2.23.0), Grok CLI `1.0.46` (cli-chat-proxy rejects versions below `1.0.13` with HTTP 426, `internal/runtime/executor/helps/xai_version.go`), Claude CLI and codex-tui user agents.

### Client adaptation

- Operational endpoints moved to `/v8/management`: `credentials`, `credentials/models`, `credentials/download`, `credentials/refresh`, `requests/api-call`, `routing/model-definitions/<channel>`, and OAuth `oauth/auth-url?provider=`, `oauth/callback`, `oauth/status`, `oauth/session`. Claude's v8 login provider is `claude`; callback bodies are unchanged. A 404 from the credential list reports that v8.0.0 or later with the management API enabled is required.
- Config reads (`*-api-key`, `openai-compatibility`, `oauth-model-alias`, `oauth-excluded-models`, `routing/strategy`, `force-model-prefix`) and client `api-keys` management stay on `/v0/management` by decision: the v8 config tree stores provider keys as groups with per-key inheritance, which needs a separate parser migration.
- Antigravity requests use `antigravity/hub/2.23.0 darwin/arm64`. The current upstream payload has `Gemini Models` and `Claude and GPT models` groups with `5h`/`weekly` buckets; both feed the Gemini and Claude/GPT 5h/7d slots. A full 5h bucket is unusable while its group's weekly bucket is exhausted, and an account-card slot whose every bucket is unusable stays unusable.
- Grok uses client version `1.0.46`. Product usage rows are a breakdown of the shared weekly credits (used percentage only), not separate remaining allowances.
- Claude sends the Claude CLI user agent. Team organizations take precedence over personal plan flags; `iguana_necktie` is the Fable 5 weekly window unless a `limits[]` `weekly_scoped` Fable entry supersedes it; dollar-denominated `iguana_necktie` is the cloud session credit pool; other full dollar records become balance rows; extra usage is shown whether enabled or not, with status, spend/limit in its currency, and flags.
- Codex sends the codex-tui user agent and shows `credits.balance` (plain non-negative decimal) or unlimited credits.
- Kimi lists rolling limits, then the weekly summary, then `usages.limit_month_total`. Protobuf units (`TIME_UNIT_MINUTE`, missing unit = minutes, weeks) render correctly; `kimi.ai`/`kimi_ai` map to Kimi.ai and its host, `kimi.com` to Kimi.
- Meta quota is supported: the persisted `dca:` token from the downloaded credential (never the LLM key) is sent to `https://api.meta.ai/muse-code/key`. Only plan, rolling-window, and weekly usage are kept; error messages never include the response body, which echoes the API key and profile data. Missing `subs_usage` stays unknown.

### Unchanged contracts

- Bearer management authentication, `auth_index`, server-side `$TOKEN$` substitution, string `api-call` `data`/`body`, nested `status_code`, the Devin refresh contract (`name` and `auth_index`, decoding only `ok` and `auth.quota`), credential list fields, model queries by account ID, per-service settings and Keychain isolation, background refresh, and local alerts.
- No plugin, Home, quota-reset, Codex reset-credit consumption, or Grok paid-account inference probe was added.

### iOS delivery and validation

- Client starting commit: `1b035a163bac330263be460a7f4e11a45e701d9e` (release `1.3.2`, build `8`). Release version: `1.4.0`, build `9`.
- iOS-specific details: the unsupported-server error uses the app's Chinese error wording, and pasted `/v8/management/...` URLs normalize to the server origin like `/v0/management/...`. No source file was added, so Xcode project membership is unchanged.
- Validation (full Xcode at `/Applications/Xcode-beta.app`; no sandbox overrides were needed):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/validate_local.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project CPA-IOS.xcodeproj -scheme CPA-IOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/cpa-ios-xcode CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-disable-sandbox' build
```

- `Scripts/validate_local.sh` passed: package build, `CPAKitValidation passed`, Swift 6 and default app typechecks, shell syntax, `git diff --check`, plist/project, scheme XML, and asset JSON checks. New checks mirror the macOS regressions (v8 paths and old-server error, OAuth `provider`/`state` queries, Antigravity/Grok/Claude/Codex identities, current Antigravity groups with weekly-blocked 5h buckets, Claude Fable/credit-pool/dollar/Team, Kimi protobuf units, monthly totals and aliases, Codex credits, Meta DCA-token contract with response secrets kept out of the dashboard snapshot, Grok product breakdown, v8 URL normalization). Fifteen single-point contract mutations on a temporary copy each failed validation. The generic iOS Simulator build reported `BUILD SUCCEEDED`. Logs: `/tmp/cpa-ios-validate-local.log`, `/tmp/cpa-ios-xcodebuild.log`.
- Not verified: no authenticated request reached a deployment or provider in this sync (the Keychain authorization prompt for a read-only diagnostic was not approved), so the effect of the new identities on live Antigravity, Grok, Claude, Codex, and Meta responses, OAuth logins, rendered UI, physical-device background refresh and alerts, signing, and distribution remain unverified.

## v7.3.11 provider sync (2026-09-21)

Endpoint paths in this section are the `/v0/management` paths of that sync; the v8.0.47 sync moved the operational ones to `/v8/management`.

### Provider adaptation

- Both native clients recognize Devin, Meta, and Kimi.ai as distinct providers and expose their authorization flows. Devin uses an authorization-code flow with a server-configured loopback port. Meta and Kimi.ai use device authorization, including user-code and expiry metadata.
- Preserve the complete Devin callback URL, validate its session state, poll until persistence succeeds, and cancel abandoned server sessions. A successful callback submission alone is not login success.
- Refresh exactly one Devin account with `POST /v0/management/auth-files/refresh`, providing `name` and `auth_index`. Decode only `ok` and `auth.quota`; credential metadata from the response is never retained in a snapshot.
- Display Devin plan and daily/weekly remaining percentages, reset times, server observation time, and provider-pool averages. Keep zero distinct from unknown; reject invalid percentages and discard windows whose reset time has passed. A missing timestamp stays visibly unknown. Refresh failures remain errors while preserving the previous dated observation.
- Keep passive quota observations separate from scheduler `cooldowns`. Neither zero remaining quota nor a model registration invents an account-wide cooldown or proves live model availability.
- Kimi.ai quota uses `https://api.kimi.ai/coding/v1/usages`; Kimi coding retains `https://api.kimi.com/coding/v1/usages`. This follows the shared coding API and upstream domain split; live Kimi.ai responses remain unverified.
- Meta account/model support does not claim an undocumented built-in quota endpoint. Add Meta and Grok API-key config channels to model/routing inventory, preserving aliases, duplicate routing targets, prefix policy, wildcard exclusions, and capability metadata.

### Contract references and preserved behavior

- OAuth: `internal/api/server_management.go`, `auth_files_devin_oauth.go`, `auth_files_provider_oauth.go`, and `docs/management-devin-oauth.md`.
- Devin quota: `internal/auth/devin/record.go`, `internal/runtime/executor/devin_executor.go`, and `auth_files_refresh.go`. `/quota/fetch` is a plugin/probe interface, not the built-in Devin refresh contract.
- Models: `sdk/cliproxy/service_models.go`, registry definitions, and the existing `auth-files/models` endpoint. Model queries continue using account IDs to disambiguate shared filenames.
- Management bearer authentication, server-side `$TOKEN$` substitution, string `api-call.data`/`body`, nested upstream `status_code`, API key operations, and per-service settings/Keychain isolation remain intact.
- The v7.3.10-to-v7.3.11 changes affect runtime translation, response streaming, schema normalization, and plugin usage metadata; the audited native management contracts remain unchanged.
- No plugin/Home administration or quota-reset controls were added. Live provider APIs, production credentials, cloud changes, and device acceptance are separate from fixture validation.

### iOS delivery and validation

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

## Grok zero-usage correction (2026-10-25)

- Client starting commit: `d4b072aab4a2fc3473ce398cc7cccf11a0319b94`. The read-only upstream reference remains `v7.3.11`, `ffe6ad3c5fcf0a5eedd2198cd2e04b0249dc5063`.
- Read-only authenticated billing requests on 2026-10-24 reproduced a weekly period with an omitted usage scalar and a monthly response with both limit and usage equal to zero. No account identifiers or credentials are retained in fixtures.
- Decode omitted ProtoJSON usage scalars only within recognized weekly/product records and decode present empty xAI `Cent` messages as zero. Explicit null, invalid values, missing records, and request failures remain unknown or errors.
- Preserve `usedPercent`, usage text, amounts, and reset metadata in Grok dashboard cards. A zero monthly limit and zero usage display `已用 0.0%`; remaining quota and usability stay unknown because a zero budget does not establish available credit. Weekly cards retain the remaining-percentage convention and also show `已用 0.0%`.
- xAI documents the empty zero-valued `Cent` representation in its [billing implementation](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs). Management endpoints, bearer authentication, server-side `$TOKEN$` substitution, other providers, and settings are unchanged.
- Release version: `1.3.2`, build `8`. The added validation source belongs only to the package validation target; no app source membership changed. Package validation, native archive/signing, installation, and App Store/TestFlight distribution are separate checks.
- The local Swift toolchain stalled during startup after a system restart. The release workflow runs `Scripts/validate_local.sh`, archives the native iOS target, and uploads an unsigned IPA plus SHA-256. An unsigned IPA requires signing before installation; development signing remains a separate local step. Swift validation builds and native archive builds use two jobs.
- The first CI run found stale validation assumptions from the earlier README split. Documentation assertions now read the README and both linked guides, and the script assertion recognizes bounded Swift concurrency. The unsuccessful `v1.3.1` tag is retained; it produced no installer.
- [GitHub Actions run 40180081960](https://github.com/gaojunbin/CPA_IOS/actions/runs/40180081960) passed package regressions, both app typechecks, resource/project checks, and the native Release archive for `28bf6252cfe32c15b889c1f7cb3043bcae094c26`.
- The downloaded unsigned IPA matched its checksum and contained the `arm64` iOS app with version `1.3.2`, build `8`. A development IPA was signed locally using an existing valid certificate and matching profile for three registered devices; strict recursive signature verification and archive integrity passed. Both IPA variants have SHA-256 checksums. Physical-device installation and rendered UI acceptance were not performed.

## Next sync

Compare `90c447d3a8727d115aa7552ec93ce023736ed492..HEAD` in the upstream reference and the management web UI after `64b4f5aed19b8f791eb21eb9e785ea379ea05b44`. Include newly introduced built-in providers, re-check the quota client identities (they track upstream release floors), and decide whether to move config reads to the v8 config tree before upstream removes `/v0/management`. Preserve accurate quota semantics, validate both native builds, and record live/cloud/distribution acceptance separately.

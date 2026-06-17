# CPA Panel App Store Metadata

Use this copy as the App Store Connect source of truth for the first iOS submission.

## App Information

- App name: CPA Panel
- Subtitle: CLIProxyAPI 额度监控
- Primary category: Developer Tools
- Secondary category: Utilities
- Content rights: The app contains original UI and generated local demo data.
- Sign-in: No account sign-in or account creation. Users connect to their own CLIProxyAPI management endpoint.

## Promotional Text

在 iPhone 和 iPad 上查看 CLIProxyAPI 账号状态、剩余额度、模型限制和低额度提醒。

## Description

CPA Panel 是面向 CLIProxyAPI 用户的移动监控工具，用于在 iPhone 和 iPad 上快速查看账号池状态和剩余额度。

你可以连接自己的 CLIProxyAPI 管理端点，查看 Codex/OpenAI、Claude、Antigravity、Kimi、Grok 等来源的实时额度窗口、冷却状态、模型限制和最近请求。不同渠道的额度展示各不相同（Codex 为 5 小时/7 天窗口、Grok 为额度余额、Antigravity 为各模型配额等），均按服务端返回的实时数据呈现；仪表盘以 Codex 账号的 5h/7d 平均剩余额度为核心指标，并按 provider 分组展示各渠道额度。

CPA Panel 只读取用户提供的管理 API，不创建账号，不管理账号池，也不把管理密钥发送到第三方服务。管理密钥保存在设备 Keychain 中，服务器地址和刷新间隔保存在本机 UserDefaults 中。内置演示面板可在不保存任何凭据的情况下查看主要界面。

可选的低额度提醒由设备本地生成，默认隐藏账号名称和服务器名称。启用提醒后，App 会注册 iOS Background App Refresh，在系统允许时补充刷新额度并生成本地提醒。用户可以在设置中调整刷新间隔、关注阈值、通知文本隐私和连接信息。

## Keywords

CLIProxyAPI,CPA,Codex,Claude,Kimi,Grok,Antigravity,quota,API Key,开发者工具

## Review Notes

CPA Panel connects to a user-provided CLIProxyAPI management endpoint and displays account status, quota windows, model runtime status badges, and recent request activity. No account is created in the app. A built-in demo dashboard with account-detail model metadata is available on the first screen for UI review without credentials. Please use the provided demo server URL and management key to test live networking.

## Privacy Answers

- Tracking: No.
- Data linked to user: None collected by the bundled app code.
- Data not linked to user: None collected by the bundled app code.
- Contacts, location, photos, camera, microphone, health, financial data: Not collected by the bundled app code.
- Local storage: Server URL and refresh interval are stored in UserDefaults; management key is stored in Keychain.
- Network: The configured management key is sent only to the user-provided CLIProxyAPI server using an Authorization header.
- Sensitive UI fields: Management key entry fields, dashboard server hosts, dashboard account identifiers, project IDs, and account-detail identifiers are marked privacy-sensitive in SwiftUI.
- Notifications: Optional low-quota alerts are local notifications only; the app does not register for remote push notifications.
- Background App Refresh: Used only to opportunistically refresh quota for enabled local low-quota alerts. iOS controls timing and the app does not perform continuous background monitoring.
- Analytics and crash reporting: None in the bundled app code.

## Screenshot Checklist

- First screen with the built-in demo action and connection form.
- Settings screen with the demo action available after a connection is saved.
- Dashboard summary showing Codex 5h/7d average remaining quota, account count, and provider sections.
- Account detail showing live quota windows, bundled demo or live model runtime status badges, recent requests, and account metadata.
- Settings screen showing refresh interval, attention threshold, local alert controls, notification delivery and badge status, Background App Refresh status, privacy-preserving notification text option, and no-key diagnostics copy action.
- Notification permission recovery, local alert behavior, Background App Refresh setting, and notification-tap dashboard view if included in the review flow.

## Required Before Upload

- Publish `SUPPORT.md` at a public HTTPS support URL and enter that URL in App Store Connect.
- Publish `PRIVACY_POLICY.md` at a public HTTPS privacy policy URL and enter that URL in App Store Connect if the distribution account requires one.
- Run `DEVELOPMENT_TEAM=YOURTEAMID Scripts/validate_xcode_release.sh` on a full Xcode machine; add `CPA_ALLOW_PROVISIONING_UPDATES=1` if automatic signing should update provisioning profiles.
- Test the archive on at least one physical iPhone against a real CLIProxyAPI server.

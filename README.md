<img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-iOS.svg" width="76" alt="CPA app icon">

# CPA for iOS

Keep your self-hosted [CLIProxyAPI (CPA)](https://github.com/router-for-me/CLIProxyAPI) within reach. Connect to CPA running on your VPS and check account status, remaining quota, and reset times directly from your iPhone.

## Features

- **Live account overview** — view accounts by provider, refresh quota, and inspect account details while away from your Mac.
- **Quota alerts** — enable optional local notifications for low quota and account issues.
- **Multiple servers** — save your CPA connections and switch between them in the app.
- **Account and model tools** — start account authorization, browse models and routing, and manage proxy API keys.
- **Demo mode** — explore the dashboard with sample data before connecting a server.

## Supported services

Manage CPA accounts for **Claude Code, Codex, Devin, Antigravity, Grok, Kimi, Kimi.ai, and Meta**, plus model and channel information for Gemini, Vertex AI, and OpenAI-compatible providers.

Available features depend on your CPA server version and provider. Live quota is shown where the provider supports it; not every service exposes quota data.

## Get started

Requires **iOS 16 or later**. Follow the [Xcode installation guide](docs/DEVELOPMENT.md#install-from-source) to install the app.

1. Open CPA and add your server's HTTPS address and management key, or try demo mode first.
2. View your accounts and quota; pull to refresh for the latest information.
3. Enable quota alerts in Settings if you want local notifications.

Your server must allow remote management. Management keys are stored in Keychain. The dashboard refreshes automatically while open; background refresh timing is controlled by iOS.

---

[macOS companion](https://github.com/gaojunbin/CPA_macos) · [Detailed guide](docs/REFERENCE.md) · [Development](docs/DEVELOPMENT.md) · [Privacy](PRIVACY_POLICY.md)

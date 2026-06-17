# CPA Panel Support

CPA Panel is a client for self-hosted CLIProxyAPI instances. It does not provide a hosted CLIProxyAPI service or create accounts inside the app.

## Before Contacting Support

Check the CLIProxyAPI server configuration first:

- Management routes are enabled.
- `remote-management.allow-remote` is enabled when connecting from iPhone or iPad.
- `remote-management.secret-key` or `MANAGEMENT_PASSWORD` is configured.
- Internet-facing servers use HTTPS.
- Local HTTP servers are reachable from the iPhone or iPad on the same trusted network.

## Common Issues

### Cannot Connect

Confirm the server URL points to the CLIProxyAPI origin, not only the browser management page. CPA Panel accepts copied URLs such as `https://example.com/management.html#/quota` and normalizes them to the server origin.

If the server is on a local network, confirm the iOS device is on the same network and that firewalls allow the CLIProxyAPI port.

### No Live Quota

Live quota requires the CLIProxyAPI `/v0/management/api-call` route. Some providers expose identity or status only; unsupported providers can still appear in the account list without live quota windows.

### Notifications Do Not Appear

Low-quota alerts are local notifications. Open iOS Settings and confirm notifications, alert presentation, badge permission, and Background App Refresh are enabled for CPA Panel. Tapping a low-quota alert opens the dashboard. If notification permission is revoked, the app disables low-quota alerts and clears pending CPA notifications the next time it launches or enters the foreground. Background refresh timing is controlled by iOS, so open CPA Panel and refresh manually when an immediate quota update is required.

### Support Diagnostics

Use Settings > Copy Diagnostics to copy generation time, app version, connection status, server URL, refresh interval, alert settings, notification authorization, alert presentation, badge availability, and Background App Refresh status. The report states whether a management key is present, but it does not include the key value.

### App Store Review

Reviewers can use the built-in demo dashboard from the first screen without credentials, including account detail with bundled model metadata and runtime badges. After a connection is saved, the same demo can be opened from Settings without clearing credentials. Live networking requires a reachable CLIProxyAPI test server URL and management key.

## Privacy

CPA Panel stores the management key in Keychain and stores the server URL, refresh interval, and local alert settings in `UserDefaults`. The bundled app code does not collect analytics or tracking data.

See `PRIVACY_POLICY.md` for the full privacy policy source.

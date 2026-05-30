import SwiftUI

struct RootView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var notificationRouter: NotificationRouter
    @State private var showsPreview = false

    var body: some View {
        Group {
            if showsPreview {
                DashboardView(
                    connection: .preview,
                    previewSnapshot: ManagementDashboard.demo(),
                    onClosePreview: { showsPreview = false }
                )
            } else if let connection = connectionStore.connection {
                DashboardView(
                    connection: connection,
                    onShowPreview: { showsPreview = true },
                    attentionFocusRequestID: notificationRouter.attentionFocusRequestID
                )
            } else {
                ConnectionSetupView {
                    showsPreview = true
                }
            }
        }
        .onReceive(notificationRouter.$attentionFocusRequestID) { requestID in
            if requestID > 0 {
                showsPreview = false
            }
        }
    }
}

struct ConnectionSetupView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    let onPreview: () -> Void

    @State private var baseURL = ""
    @State private var managementKey = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 38, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 76, height: 76)
                                .background(
                                    LinearGradient(
                                        colors: [Color.teal, Color.cyan],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                                )
                                .shadow(color: Color.teal.opacity(0.35), radius: 14, x: 0, y: 8)

                            Text("CPA 面板")
                                .font(.system(size: 34, weight: .bold, design: .rounded))

                            Text("连接 CLIProxyAPI 后台")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 28)

                        VStack(spacing: 14) {
                            InputField(
                                title: "服务器",
                                systemImage: "link",
                                placeholder: "https://cpa.example.com",
                                text: $baseURL,
                                isSecure: false,
                                isSensitive: true
                            )

                            InputField(
                                title: "管理密钥",
                                systemImage: "key.fill",
                                placeholder: "Management key",
                                text: $managementKey,
                                isSecure: true,
                                isSensitive: true
                            )

                            if let normalized = try? CPABaseURLNormalizer.normalize(baseURL),
                               normalized.scheme == "http" {
                                Label("当前连接使用 HTTP，请只在可信网络中使用。", systemImage: "lock.open.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                Task {
                                    await connect()
                                }
                            } label: {
                                HStack {
                                    if isConnecting {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "bolt.horizontal.circle.fill")
                                    }
                                    Text(isConnecting ? "连接中" : "连接")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canConnect)

                            Button {
                                onPreview()
                            } label: {
                                Label("查看演示面板", systemImage: "rectangle.on.rectangle")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(16)
                        .cpaCard()
                    }
                    .padding(20)
                }
            }
            .navigationTitle("")
            .onAppear {
                if baseURL.isEmpty {
                    baseURL = connectionStore.lastBaseURLString
                }
            }
        }
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        do {
            let normalizedURL = try CPABaseURLNormalizer.normalize(baseURL)
            let key = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ConnectionError.emptyManagementKey
            }
            let client = CPAClient(baseURL: normalizedURL, managementKey: key)
            _ = try await client.fetchDashboard(includeLiveUsage: false)
            try connectionStore.save(baseURLString: normalizedURL.absoluteString, managementKey: key)
        } catch {
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 180)
        }
        isConnecting = false
    }

    private var canConnect: Bool {
        !isConnecting &&
            !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct InputField: View {
    let title: String
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    let isSensitive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
            }
            .textContentType(isSecure ? .password : .URL)
            .privacySensitive(isSensitive)
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .frame(height: 48)
            .cpaFieldSurface()
        }
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.cpaSystemBackground

            // Soft teal aurora anchored in the top-leading corner.
            RadialGradient(
                colors: [Color.teal.opacity(0.20), Color.teal.opacity(0.0)],
                center: .topLeading,
                startRadius: 0,
                endRadius: 540
            )

            // Cooler indigo wash drifting up from the bottom-trailing corner.
            RadialGradient(
                colors: [Color.indigo.opacity(0.16), Color.indigo.opacity(0.0)],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 580
            )
        }
        .ignoresSafeArea()
    }
}

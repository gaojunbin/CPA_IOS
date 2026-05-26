import SwiftUI

struct RootView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore

    var body: some View {
        Group {
            if let connection = connectionStore.connection {
                DashboardView(connection: connection)
            } else {
                ConnectionSetupView()
            }
        }
    }
}

struct ConnectionSetupView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore

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
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 42, weight: .semibold))
                                .foregroundStyle(.teal)
                                .symbolRenderingMode(.hierarchical)

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
                                isSecure: false
                            )

                            InputField(
                                title: "管理密钥",
                                systemImage: "key.fill",
                                placeholder: "Management key",
                                text: $managementKey,
                                isSecure: true
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
                            .disabled(isConnecting)
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            _ = try await client.fetchDashboard()
            try connectionStore.save(baseURLString: normalizedURL.absoluteString, managementKey: key)
        } catch {
            errorMessage = error.localizedDescription
        }
        isConnecting = false
    }
}

struct InputField: View {
    let title: String
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool

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
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.cpaSystemBackground,
                Color.teal.opacity(0.08),
                Color.indigo.opacity(0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

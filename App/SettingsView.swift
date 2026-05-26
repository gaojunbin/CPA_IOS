import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var managementKey = ""
    @State private var errorMessage: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    TextField("服务器", text: $baseURL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    SecureField("管理密钥，留空保持当前密钥", text: $managementKey)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await save()
                        }
                    } label: {
                        Label(isChecking ? "验证中" : "保存并验证", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(isChecking)

                    Button(role: .destructive) {
                        connectionStore.clear()
                        dismiss()
                    } label: {
                        Label("清除连接", systemImage: "trash.fill")
                    }
                }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                baseURL = connectionStore.connection?.baseURL.absoluteString ?? connectionStore.lastBaseURLString
            }
        }
    }

    private func save() async {
        isChecking = true
        errorMessage = nil
        do {
            let normalizedURL = try CPABaseURLNormalizer.normalize(baseURL)
            let keyInput = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = keyInput.isEmpty ? connectionStore.connection?.managementKey ?? "" : keyInput
            guard !key.isEmpty else {
                throw ConnectionError.emptyManagementKey
            }
            let client = CPAClient(baseURL: normalizedURL, managementKey: key)
            _ = try await client.fetchDashboard()
            try connectionStore.save(baseURLString: normalizedURL.absoluteString, managementKey: key)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isChecking = false
    }
}

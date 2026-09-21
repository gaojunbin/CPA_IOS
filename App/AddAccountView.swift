import SwiftUI

struct AddAccountView: View {
    let client: CPAClient
    let onCompleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var provider: OAuthProvider?
    @State private var authorization: OAuthAuthURL?
    @State private var callback = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var callbackSubmitted = false
    @State private var isFinished = false

    var body: some View {
        NavigationStack {
            Form {
                if let provider {
                    Section(provider.displayName) {
                        if let authorization, let url = URL(string: authorization.url) {
                            Link("打开授权页面", destination: url)
                            ShareLink("复制或分享授权链接", item: url)
                            if let code = authorization.userCode {
                                LabeledContent("设备码", value: code).textSelection(.enabled)
                            }
                            if !provider.usesDeviceFlow && !authorization.isDeviceFlow {
                                Text("完成浏览器登录后，复制地址栏中的完整回调链接。即使回调页面无法打开，也可粘贴到下方继续。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                TextField("http://127.0.0.1:端口/callback?…", text: $callback, axis: .vertical)
                                    .autocorrectionDisabled()
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                    #endif
                                    .privacySensitive()
                                Button(callbackSubmitted ? "重新提交回调链接" : "提交回调链接") {
                                    Task { await submitCallback(provider, authorization) }
                                }
                                .disabled(callback.isEmpty || isSubmitting)
                            }
                            if !isFinished { ProgressView(callbackSubmitted ? "正在验证并保存账号…" : "等待授权完成…") }
                        } else if errorMessage == nil {
                            ProgressView("正在获取授权链接…")
                        }
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                    Section {
                        Button("重新选择登录方式") { reset() }
                    }
                } else {
                    Section("选择账号来源") {
                        ForEach(OAuthProvider.allCases, id: \.self) { provider in
                            Button { self.provider = provider } label: {
                                Label(provider.displayName, systemImage: ProviderCatalog.info(for: provider.catalogKey).symbolName)
                            }
                        }
                    }
                }
            }
            .navigationTitle("新增账号")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task(id: provider) {
                guard let provider else { return }
                await authorize(provider)
            }
            .onDisappear { cancelSession() }
        }
    }

    @MainActor
    private func authorize(_ provider: OAuthProvider) async {
        do {
            let auth = try await client.requestOAuthURL(for: provider)
            guard !Task.isCancelled else {
                try? await client.cancelOAuthSession(state: auth.state)
                return
            }
            authorization = auth
            let lifetime = max(1, min(auth.expiresIn ?? (provider.usesDeviceFlow ? 1800 : 300), 3600))
            let deadline = Date().addingTimeInterval(TimeInterval(lifetime))
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let status = try await client.pollOAuthStatus(state: auth.state)
                try Task.checkCancellation()
                switch status {
                case .ok:
                    isFinished = true
                    authorization = nil
                    onCompleted()
                    dismiss()
                    return
                case .wait: continue
                case .error(let message): throw OAuthError.providerError(message)
                }
            }
            throw OAuthError.timeout
        } catch {
            guard !Task.isCancelled else { return }
            isFinished = true
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 180)
            cancelSession()
        }
    }

    @MainActor
    private func submitCallback(_ provider: OAuthProvider, _ auth: OAuthAuthURL) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await client.submitOAuthCallback(provider: provider.callbackProvider, redirectURL: callback, state: auth.state)
            guard authorization?.state == auth.state else { return }
            callback = ""
            callbackSubmitted = true
            errorMessage = nil
        } catch {
            guard authorization?.state == auth.state else { return }
            errorMessage = displayErrorMessage(error.localizedDescription, limit: 180)
        }
    }

    private func cancelSession() {
        guard let state = authorization?.state else { return }
        authorization = nil
        Task { try? await client.cancelOAuthSession(state: state) }
    }

    private func reset() {
        cancelSession()
        provider = nil
        callback = ""
        callbackSubmitted = false
        errorMessage = nil
        isFinished = false
    }
}

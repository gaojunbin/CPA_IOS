import Foundation
import CPAKit

func validateConfiguredModels(_ check: (Bool, String) throws -> Void) throws {
    // Fixture shapes follow CLIProxyAPI v7.2.155 config handlers and model registration.
    for kind in APIKeyChannelKind.allCases {
        let root: [String: Any] = [kind.rawValue: [[
            "api-key": "",
            "base-url": "http://localhost:8080/v1",
            "prefix": "team",
            "excluded-models": ["blocked-*"],
            "models": [
                ["name": "upstream-a", "alias": "blocked-a"],
                ["name": "upstream-b", "alias": "chat", "display-name": "Custom Chat",
                 "max-context-length": 1_048_576, "thinking": ["levels": ["low", "high"]]],
                ["name": "upstream-c", "alias": "chat", "display-name": "Second Route"]
            ]
        ]]]
        let entries = ConfigChannelSynthesizer.apiKeyEntries(kind: kind, root: root)
        let accounts = ConfigChannelSynthesizer.apiKeyAccounts(
            kind: kind, entries: entries, staticModels: [CPAModelDefinition(id: "default-only")]
        )
        try check(accounts.count == 1, "Base-URL-only credentials must remain visible")
        let account = accounts[0]
        try check(account.models.map(\.id) == ["chat", "team/chat"], "Exclusions apply to aliases before prefix expansion")
        try check(account.routes.map(\.name) == ["upstream-b", "upstream-c"], "Distinct upstreams sharing an alias must remain visible")
        for model in account.models {
            try check(model.displayName == "Custom Chat", "First configured display name must survive deduplication and prefixes")
            try check(model.contextLength == 1_048_576, "Configured context length must survive prefixes")
            try check(model.thinking?.levels == ["low", "high"], "Configured thinking capabilities must survive prefixes")
        }

        let excludedRoot: [String: Any] = [kind.rawValue: [[
            "models": [["name": "upstream", "alias": "blocked"]], "excluded-models": ["blocked"]
        ]]]
        let excluded = ConfigChannelSynthesizer.apiKeyAccounts(
            kind: kind,
            entries: ConfigChannelSynthesizer.apiKeyEntries(kind: kind, root: excludedRoot),
            staticModels: [CPAModelDefinition(id: "unrelated-default")]
        )
        try check(excluded.first?.models.isEmpty == true, "Fully excluded overrides must not restore default models")
        try check(excluded.first?.routes.isEmpty == true, "Fully excluded routes must not remain advertised")

        let defaults = ConfigChannelSynthesizer.apiKeyAccounts(
            kind: kind,
            entries: [APIKeyChannelEntry(overrideModelIDs: [], excludedPatterns: [], prefix: "team")],
            staticModels: [CPAModelDefinition(
                id: "default", displayName: "Default Model", description: "Static metadata",
                contextLength: 200_000, maxCompletionTokens: 32_000,
                supportedInputModalities: ["text", "image"], supportedOutputModalities: ["text"],
                supportsWebSearch: true
            )]
        )
        for model in defaults[0].models {
            try check(model.displayName == "Default Model", "Static display names must survive prefixes")
            try check(model.contextLength == 200_000 && model.maxCompletionTokens == 32_000, "Static token limits must remain intact")
            try check(model.supportedInputModalities == ["text", "image"] && model.supportsWebSearch == true, "Static capabilities must remain intact")
            try check(model.description == "Static metadata", "Static descriptions must remain intact")
        }
    }

    let compat = ConfigChannelSynthesizer.compatAccounts(root: ["openai-compatibility": [[
        "name": "gateway", "prefix": "team", "base-url": "http://localhost:8080/v1",
        "models": [["name": "upstream", "alias": "chat", "display-name": "Gateway Chat",
                    "max-context-length": 128_000, "input-modalities": ["TEXT", "IMAGE"],
                    "output-modalities": ["TEXT"]]]
    ]]])
    try check(compat.count == 1, "Keyless compatibility channels must remain visible")
    try check(compat[0].models.map(\.id) == ["chat", "team/chat"], "Compatibility prefixes must remain intact")
    for model in compat[0].models {
        try check(model.displayName == "Gateway Chat" && model.contextLength == 128_000, "Compatibility model metadata must remain intact")
        try check(model.supportedInputModalities == ["text", "image"], "Configured input modalities must be normalized")
        try check(model.supportedOutputModalities == ["text"], "Configured output modalities must remain intact")
    }
}

func validateManagementRuntimeCompatibility() throws {
    let data = Data(#"{"files":[{"id":"account","name":"account.json","provider":"codex","auth_index":"index","status":"active","quota":{"observed_at":"2026-09-09T00:00:00Z","signals":{"X-Codex-Primary-Used-Percent":"100"}},"model_quotas":{"model":{"signals":{"X-Codex-Primary-Used-Percent":"100"}}}}]}"#.utf8)
    let account = try require(JSONDecoder().decode(AuthFilesResponse.self, from: data).files.first, "Missing account")
    try expect(!account.hasModelRuntimeStatus, "Passive model quota signals must not imply runtime-state availability")
    try expect(account.quota?.exceeded == false && account.nextRecoveryDate == nil, "Passive quota observations must not become scheduler cooldowns")
    try expect(account.quotaLine == "账号就绪", "An active account does not prove available quota")
    let empty = try JSONDecoder().decode(CPAAccount.self, from: Data(#"{"id":"empty","model_states":{}}"#.utf8))
    try expect(empty.hasModelRuntimeStatus, "An explicitly returned runtime-state dictionary must be recognized")
    for status in ["error", "failed", "disabled"] {
        let failed = CPAAccount(id: status, name: status, status: status)
        try expect(!AccountQuota(account: failed, usage: nil, errorMessage: nil).isHealthy, "Backend error status must not count as healthy")
    }
}

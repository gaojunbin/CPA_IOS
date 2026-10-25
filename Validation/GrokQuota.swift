import Foundation
import CPAKit

func validateGrokZeroUsage() throws {
    for zero in ["0", "\"0\"", "\"0%\""] {
        let usage = try require(UsageParser.parse("""
        {"_provider":"xai","weekly":{"config":{"creditUsagePercent":\(zero)}},
         "monthly":{"config":{"monthlyLimit":{"val":10000},"used":{"val":0}}}}
        """), "Explicit Grok zero usage must parse")
        for id in ["xai-weekly-credits", "xai-monthly-credits"] {
            let window = try require(usage.additionalWindows.first { $0.id == id }, "Missing Grok quota window")
            try expect(window.usedPercent == 0 && window.remainingPercent == 100, "Unused Grok quota must remain full")
            try expect(window.displayValue == "100%" && !window.isExhausted, "Zero used is not exhausted quota")
        }
    }

    let omitted = try require(UsageParser.parse(#"{"_provider":"xai","weekly":{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"productUsage":[{"product":"Grok Code"}]}},"monthly":{"config":{"monthlyLimit":{"val":10000},"used":{},"onDemandCap":{"val":5000},"onDemandUsed":{}}}}"#), "ProtoJSON zero usage must parse")
    try expect(omitted.additionalWindows.allSatisfy { $0.usedPercent == 0 && $0.remainingPercent == 100 }, "Omitted usage scalars and empty Cent messages represent zero")
    try expect(omitted.additionalWindows.last?.amountText == "$0.00 / $100.00", "Empty Cent usage must retain its amount")

    let auth = try JSONDecoder().decode(CPAAccount.self, from: Data(#"{"id":"grok","name":"grok.json","provider":"xai","auth_index":"grok-index","status":"active"}"#.utf8))
    for zero in ["{}", "{\"val\":0}"] {
        let usage = try require(UsageParser.parse("""
        {"_provider":"xai","weekly":{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2099-01-08T00:00:00Z"}}},
         "monthly":{"config":{"monthlyLimit":\(zero),"used":\(zero),"onDemandCap":\(zero)}}}
        """), "Zero-budget Grok billing must parse")
        let account = AccountQuota(account: auth, usage: usage, errorMessage: nil)
        let weekly = try require(account.dashboardQuotaWindows.first { $0.label == "周积分" }, "Missing Grok weekly card")
        try expect(weekly.remainingPercent == 100 && weekly.amountText == "已用 0.0%", "The dashboard must show zero weekly usage")
        try expect(weekly.resetAt != nil, "The weekly card must preserve its reset time")
        let monthly = try require(account.dashboardQuotaWindows.first { $0.label == "月积分" }, "Missing Grok monthly card")
        try expect(monthly.usedPercent == 0 && monthly.displayValue == "已用 0.0%", "The monthly card must preserve zero usage without a positive budget")
        try expect(monthly.amountText == "$0.00 / $0.00", "The monthly card must preserve zero amounts")
        try expect(monthly.remainingPercent == nil && monthly.isUsable == nil && !monthly.isExhausted, "A zero budget does not establish remaining quota or exhaustion")
        try expect(account.isHealthy && ProviderQuotaMetricKind.xaiMonthly.remainingPercent(in: account) == nil, "Usage-only signals must not invent pool availability")
    }

    for body in [
        #"{"_provider":"xai","weekly":{},"monthly":{}}"#,
        #"{"_provider":"xai","weekly":{"config":null},"monthly":{"config":null}}"#,
        #"{"_provider":"xai","weekly":{"config":{"creditUsagePercent":false,"currentPeriod":{"type":"weekly"}}},"monthly":{"config":{"monthlyLimit":{"val":10000},"used":{"val":null}}}}"#,
        #"{"_provider":"xai","weekly":{"config":{"creditUsagePercent":"invalid","currentPeriod":{"type":"weekly"}}},"monthly":{"config":{"monthlyLimit":{"val":0}}}}"#,
        #"{"_provider":"xai","weekly":{"config":{"creditUsagePercent":null,"currentPeriod":{"type":"weekly"}}},"monthly":{"config":{"monthlyLimit":{"val":10000},"used":{"unexpected":0}}}}"#
    ] {
        let windows = UsageParser.parse(body)?.additionalWindows ?? []
        try expect(windows.allSatisfy { $0.usedPercent == nil && $0.remainingPercent == nil }, "Missing or invalid Grok responses must remain unknown")
    }

    let exhausted = try require(UsageParser.parse(#"{"_provider":"xai","weekly":{"config":{"creditUsagePercent":100}},"monthly":{"config":{"monthlyLimit":10000,"used":10000}}}"#), "Exhausted Grok quota must parse")
    for window in exhausted.additionalWindows where window.id != "xai-pay-as-you-go" {
        try expect(window.usedPercent == 100 && window.remainingPercent == 0 && window.displayValue == "0.0%" && window.isExhausted, "Exhausted quota must still show zero remaining")
    }
}

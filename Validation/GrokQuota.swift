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
    try expect(omitted.additionalWindows.allSatisfy { $0.usedPercent == 0 }, "Omitted usage scalars and empty Cent messages represent zero")
    // Product rows only break down the shared weekly usage.
    try expect(omitted.additionalWindows.allSatisfy { $0.remainingPercent == ($0.id == "xai-product-grok-code" ? nil : 100) }, "Only allowances report remaining quota")
    try expect(omitted.additionalWindows.first { $0.id == "xai-product-grok-code" }?.displayValue == "已用 0.0%", "Zero product usage must remain visible")
    try expect(omitted.additionalWindows.last?.amountText == "$0.00 / $100.00", "Empty Cent usage must retain its amount")
    try validateGrokProductBreakdown()

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

private func validateGrokProductBreakdown() throws {
    let usage = try require(UsageParser.parse("""
    {
      "_provider": "xai",
      "weekly": {
        "config": {
          "currentPeriod": { "type": "weekly", "start": "2026-07-06T00:00:00Z", "end": "2026-07-13T00:00:00Z" },
          "creditUsagePercent": 35,
          "productUsage": [
            { "product": "Grok 4 Fast", "usagePercent": 80 },
            { "product": "Grok Code", "usage_percent": "12.5" }
          ]
        }
      },
      "monthly": {
        "config": {
          "monthlyLimit": { "val": 10000 },
          "used": { "val": 2500 },
          "onDemandCap": { "val": 5000 },
          "onDemandUsed": { "val": 1000 },
          "billingPeriodEnd": "2026-08-01T00:00:00Z"
        }
      }
    }
    """), "Wrapped Grok billing with product usage must parse")
    let windows = usage.additionalWindows
    try expect(windows.map(\.label) == ["周积分", "Grok 4 Fast 使用", "Grok Code 使用", "按量付费", "月度积分"], "Grok rows must keep the web UI order")
    try expect(windows[0].remainingPercent == 65, "Weekly credits keep the remaining-percentage convention")
    // Product rows break down the shared weekly credits instead of acting as separate allowances.
    let product = windows[1]
    try expect(product.usedPercent == 80 && product.remainingPercent == nil && product.isUsable == nil, "Product rows must not claim a separate allowance")
    try expect(product.displayValue == "已用 80%" && product.detailText == "共享配额明细" && product.resetAt == nil, "Product rows must read as shared usage")
    try expect(windows[2].usedPercent == 12.5 && windows[2].remainingPercent == nil, "Every product row is a usage breakdown")
    try expect(windows[3].remainingPercent == 80 && windows[3].amountText == "已用 $10.00 / 封顶 $50.00", "On-demand billing must remain intact")
    try expect(windows[4].remainingPercent == 75 && windows[4].amountText == "$25.00 / $100.00", "Monthly billing must remain intact")
}

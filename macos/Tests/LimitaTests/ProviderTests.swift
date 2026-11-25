import XCTest
@testable import Limita

final class ProviderTests: XCTestCase {
    func testLocalFakeAPI() async throws {
        try XCTSkipUnless(ProviderClient.isDemo, "Start scripts/fake-api.py and set LIMITA_FAKE_PROVIDERS=1")
        let cases: [(Service, String, String, Int, Bool)] = [
            (.zaiCoding, "demo", "", 3, false),
            (.zaiAPI, "demo-session", "demo", 0, true),
            (.qwenCoding, "", "", 3, false),
            (.qwenToken, "", "", 1, false),
            (.qwenAPI, "", "", 0, true),
            (.openCodeGo, "demo", "", 3, false),
            (.openCodeAPI, "demo", "org_demo", 0, true),
            (.openRouter, "demo-management", "", 0, true),
        ]
        for (service, key, workspace, quotas, billing) in cases {
            let reading = try await ProviderClient.fetch(service, supplied: .init(key: key, workspace: workspace))
            XCTAssertEqual(reading.details.provider?.quotas.count, quotas, service.rawValue)
            if billing {
                XCTAssertGreaterThan(reading.snapshot.balance?.total ?? 0, 0, service.rawValue)
                XCTAssertGreaterThan(reading.details.provider?.history?.days.count ?? 0, 15, service.rawValue)
            }
        }
        let regular = try await ProviderClient.fetch(.openRouter, supplied: .init(key: "demo"))
        XCTAssertNil(regular.snapshot.balance)
        XCTAssertEqual(regular.details.provider?.history?.days.values.first, ["": 0.53])
        let partial = try await ProviderClient.fetch(.openCodeAPI, supplied: .init(key: "demo-partial", workspace: "org_demo"))
        XCTAssertNil(partial.snapshot.balance)
        XCTAssertFalse(partial.details.provider?.history?.days.isEmpty ?? true)
        do {
            _ = try await ProviderClient.fetch(.openCodeGo, supplied: .init(key: "demo-bad"))
            XCTFail("Invalid credentials should be rejected")
        } catch let failure as ProviderClient.Failure {
            XCTAssertEqual(failure.status, 401)
        }
        do {
            _ = try await ProviderClient.fetch(.openCodeGo, supplied: .init(key: "demo-limited"))
            XCTFail("Expected a rate limit")
        } catch let error as ProviderClient.Throttled {
            XCTAssertEqual(error.retryAfter, 15)
        }
        let device = try await ProviderClient.beginOpenCodeSignIn()
        XCTAssertEqual(device.user_code, "DEMO-1234")
        let credentials = try await ProviderClient.finishOpenCodeSignIn(device)
        XCTAssertEqual(credentials.workspace, "org_demo")
    }

    func testBailianQuotaRatiosAndMissingWindows() {
        let quota = ProviderClient.qwenQuotas([
            "per5Hour": ["percentage": 0.25, "resetTime": 1_800_000_000_000],
            "perWeek": ["percentage": 0],
            "perBillMonth": [:],
        ], coding: true)
        XCTAssertEqual(quota.map(\.shortName), ["5h", "7d"])
        XCTAssertEqual(quota.map(\.window.usedPercent), [25, 0])
        XCTAssertEqual(quota.first?.window.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(ProviderClient.qwenQuotas(["hasQuotaData": false], coding: false).isEmpty)
    }

    func testBillingSeparatesDailyModelCharges() {
        let data: ProviderClient.JSON = [
            "data": [
                "costTotals": ["currency": "USD"],
                "resultByTime": [[
                    "period": "20261124",
                    "total": ["amount": "0.15"],
                    "periodDetails": [["key": "qwen-plus", "amount": "0.10"]],
                ]],
            ],
        ]
        let history = ProviderClient.qwenHistory(data)
        XCTAssertEqual(history?.currency, "USD")
        XCTAssertEqual(history?.days["2026-11-24"]?["qwen-plus"], 0.10)
        XCTAssertEqual(history?.days["2026-11-24"]?["Other"] ?? -1, 0.05, accuracy: 0.000001)
        XCTAssertNil(history?.days["2026-11-23"])
    }

    func testOpenCodeCSVParsesQuotedColumnsAndMicroCents() throws {
        let csv = "day,user,provider,model,cost_micro_cents\r\n2026-11-24,\"Last, First\",opencode,qwen,25000000\r\n2026-11-24,A,opencode-go,qwen,5000000\r\n2026-11-24,A,external,qwen,100000000\r\n"
        let history = try ProviderClient.openCodeHistory(csv)
        XCTAssertEqual(history.days["2026-11-24"]?["qwen"] ?? -1, 0.30, accuracy: 0.000001)
    }
}

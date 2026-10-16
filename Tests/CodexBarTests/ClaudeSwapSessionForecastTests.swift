import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeSwapSessionForecastTests {
    @Test
    func `fresh measurements record history under each account fingerprint`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let accounts = Self.accounts([
            Self.row(number: 1, email: "one@example.com", sessionUsed: 30, weeklyUsed: 40),
            Self.row(number: 2, email: "two@example.com", sessionUsed: 50, weeklyUsed: 60),
        ])

        await store.recordClaudeSwapPlanUtilizationHistory(accounts)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        let keys = try accounts.map { try #require(UsageStore.claudeSwapPlanUtilizationAccountKey(for: $0)) }
        #expect(Set(buckets.accounts.keys) == Set(keys))
        #expect(keys.allSatisfy { !$0.contains("example.com") })
        #expect(buckets.preferredAccountKey == nil)
        #expect(buckets.unscoped.isEmpty)
        let session = try #require(buckets.histories(for: keys[1]).first { $0.name == .session })
        #expect(session.entries.map(\.usedPercent) == [50])
        #expect(session.entries.map(\.capturedAt) == [Self.fetchedAt])
    }

    @Test
    func `last known and unavailable rows record nothing`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let lastGood = ClaudeSwapLastGoodUsage(
            measurement: ClaudeSwapUsageMeasurement(
                fiveHour: ClaudeSwapUsageWindow(usedPercent: 70, resetsAt: Self.sessionReset),
                sevenDay: ClaudeSwapUsageWindow(usedPercent: 80, resetsAt: Self.weeklyReset)),
            fetchedAt: Self.fetchedAt.addingTimeInterval(-3600))
        let accounts = Self.accounts([
            Self.row(number: 1, email: "one@example.com", status: .tokenExpired, lastGoodUsage: lastGood),
            Self.row(number: 2, email: "two@example.com", status: .unavailable, sessionUsed: 100, weeklyUsed: 90),
        ])

        await store.recordClaudeSwapPlanUtilizationHistory(accounts)

        #expect(store.planUtilizationHistory[.claude] == nil)
    }

    @Test
    func `recording swap history fires no limit reset detection`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let beforeReset = Self.accounts([Self.row(number: 1, email: "one@example.com", sessionUsed: 100)])
        let resetAt = Self.sessionReset.addingTimeInterval(60)
        let afterReset = Self.accounts(
            [Self.row(
                number: 1,
                email: "one@example.com",
                sessionUsed: 0,
                sessionReset: Self.sessionReset.addingTimeInterval(18000),
                fetchedAt: resetAt)],
            now: resetAt)

        await store.recordClaudeSwapPlanUtilizationHistory(beforeReset)
        await store.recordClaudeSwapPlanUtilizationHistory(afterReset)

        #expect(store.settings.userDefaults.object(forKey: UsageStore.sessionLimitResetDetectorDefaultsKey) == nil)
    }

    @Test
    func `swap card shows the session forecast from its own history`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let fixture = SessionEquivalentForecastTests.historyFixture(burns: [4, 8, 6])
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let account = try #require(Self.accounts(
            [Self.row(
                number: 1,
                email: "one@example.com",
                sessionUsed: 20,
                weeklyUsed: 60,
                sessionReset: fixture.currentSessionReset,
                weeklyReset: now.addingTimeInterval(2 * 24 * 3600),
                fetchedAt: now)],
            now: now).first)
        let accountKey = try #require(UsageStore.claudeSwapPlanUtilizationAccountKey(for: account))
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.setHistories(fixture.histories, for: accountKey)
        store.planUtilizationHistory[.claude] = buckets

        func forecast(_ selection: PlanUtilizationHistorySelection?) -> SessionEquivalentForecast? {
            store.menuCardInput(
                for: .claude,
                context: ClaudeSwapAccountMenuDisplay.cardContext(
                    for: account,
                    planLabel: nil,
                    adapterError: nil,
                    switchError: nil,
                    historySelection: selection),
                now: now).sessionEquivalentForecast
        }

        #expect(forecast(nil) == nil)
        #expect(forecast(store.claudeSwapPlanUtilizationHistorySelection(for: account)) != nil)
    }

    @Test
    func `ambient history never falls back to a swap bucket`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        await store.recordClaudeSwapPlanUtilizationHistory(
            Self.accounts([Self.row(number: 1, email: "one@example.com", sessionUsed: 30)]))
        #expect(store.planUtilizationHistory[.claude]?.accounts.isEmpty == false)

        #expect(store.planUtilizationHistorySelection(for: .claude).histories.isEmpty)
    }

    // MARK: - Fixtures

    private static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let sessionReset = fetchedAt.addingTimeInterval(3600)
    private static let weeklyReset = fetchedAt.addingTimeInterval(3 * 24 * 3600)

    private static func row(
        number: Int,
        email: String,
        status: ClaudeSwapUsageStatus = .ok,
        sessionUsed: Double? = nil,
        weeklyUsed: Double = 40,
        sessionReset: Date = sessionReset,
        weeklyReset: Date = weeklyReset,
        fetchedAt: Date = fetchedAt,
        lastGoodUsage: ClaudeSwapLastGoodUsage? = nil) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            isActive: number == 1,
            usageStatus: status,
            fiveHour: sessionUsed.map { ClaudeSwapUsageWindow(usedPercent: $0, resetsAt: sessionReset) },
            sevenDay: sessionUsed == nil ? nil : ClaudeSwapUsageWindow(usedPercent: weeklyUsed, resetsAt: weeklyReset),
            usageFetchedAt: fetchedAt,
            lastGoodUsage: lastGoodUsage)
    }

    private static func accounts(
        _ rows: [ClaudeSwapAccountRow],
        now: Date = fetchedAt) -> [ProviderAccountUsageSnapshot]
    {
        ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(activeAccountNumber: 1, accounts: rows),
            now: now)
    }
}

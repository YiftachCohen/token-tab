// Expiry rules for the LEARNED 5-hour cap (UsageStore.calibratedCap / calibratedCapAt).
//
// The cap is `windowTokens / sessionPct` — a token count over a MODEL-WEIGHTED server
// percentage — so it is only true while the mix that produced it is. It used to be persisted
// with no age at all: a helper that stopped writing left the last cap in force forever, and a
// real 46-hour outage had the ring headlining "78% left" against a true 42%. These tests pin
// the fix — the cap ages out, an admissible reading keeps it alive, and neither a manual nor a
// configured cap is affected (they are stated intent, not inference).
//
// UsageStore reads UserDefaults.standard directly, so each test stashes and restores the two
// keys it touches rather than leaving a learned cap behind in the test runner's domain.

import XCTest
@testable import TokenTab

@MainActor
final class CalibratedCapExpiryTests: XCTestCase {
    private let capKey = "calibratedCap"
    private let atKey = "calibratedCapAt"
    private let overrideKey = "windowCap"
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in [capKey, atKey, overrideKey] { saved[key] = UserDefaults.standard.object(forKey: key) }
        for key in [capKey, atKey, overrideKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        saved = [:]
        super.tearDown()
    }

    /// Seed the persisted state a fresh launch would read, then build the store that reads it.
    private func store(cap: Int, learnedAt: Date?) -> UsageStore {
        UserDefaults.standard.set(cap, forKey: capKey)
        if let learnedAt { UserDefaults.standard.set(learnedAt.timeIntervalSince1970, forKey: atKey) }
        else { UserDefaults.standard.removeObject(forKey: atKey) }
        return UsageStore(logDir: { nil }, codexDir: { nil })
    }

    private var maxAge: TimeInterval { UsageStore.calibratedCapMaxAge }

    func testFreshLearnedCapIsUsed() {
        let s = store(cap: 136_000_000, learnedAt: Date().addingTimeInterval(-3600))
        XCTAssertFalse(s.calibratedCapIsStale(now: Date()))
        XCTAssertEqual(s.effectiveCap, 136_000_000)
    }

    /// The regression this whole change exists for: two days without a live reading must not
    /// leave a two-day-old ratio underwriting the hero percentage.
    /// Expired means it leaves the precedence chain entirely — falling through to whatever
    /// `TOKENTAB_WINDOW_CAP` says, which is 0 on a machine that configures none. Asserted
    /// against `Config.windowCap` rather than 0 so the test doesn't depend on whether the
    /// person running it happens to have a cap in ~/.config/token-tab/env.
    func testCapOlderThanMaxAgeExpires() {
        let s = store(cap: 136_000_000, learnedAt: Date().addingTimeInterval(-46 * 3600))
        XCTAssertTrue(s.calibratedCapIsStale(now: Date()))
        XCTAssertEqual(s.effectiveCap, Config.windowCap, "an expired cap must fall through, not linger")
        XCTAssertNotEqual(s.effectiveCap, 136_000_000)
    }

    /// The boundary is a real cliff, so pin both sides of it rather than a comfortable middle.
    func testBoundaryIsInclusiveOfTheFullWindow() {
        let now = Date()
        let justInside = store(cap: 50_000_000, learnedAt: now.addingTimeInterval(-maxAge + 60))
        XCTAssertFalse(justInside.calibratedCapIsStale(now: now))

        let justOutside = store(cap: 50_000_000, learnedAt: now.addingTimeInterval(-maxAge - 60))
        XCTAssertTrue(justOutside.calibratedCapIsStale(now: now))
    }

    /// No cap means nothing to distrust — `isStale` is about a value in force, and reporting
    /// true here would make the UI explain an expiry that never happened.
    func testNoCapIsNotStale() {
        let s = store(cap: 0, learnedAt: nil)
        XCTAssertFalse(s.calibratedCapIsStale(now: Date()))
    }

    /// Upgrade path: a cap persisted before `calibratedCapAt` existed gets stamped at first
    /// launch (not voided — only a live reading can re-learn it, so voiding would strip the %
    /// permanently from anyone running with live off).
    func testCapFromBeforeTheTimestampExistedIsGrantedOneWindow() {
        let s = store(cap: 90_000_000, learnedAt: nil)
        XCTAssertFalse(s.calibratedCapIsStale(now: Date()))
        XCTAssertEqual(s.effectiveCap, 90_000_000)
        XCTAssertNotNil(s.calibratedCapAt)
    }

    /// ...and that stamp must be WRITTEN, not just held in memory. Property observers don't run
    /// during init, so a missed explicit write would re-stamp `now` on every launch and make the
    /// migrated cap immortal — the exact bug the expiry is meant to end.
    func testMigrationStampIsPersistedSoItCannotReStampEveryLaunch() {
        _ = store(cap: 90_000_000, learnedAt: nil)
        let stamped = UserDefaults.standard.double(forKey: atKey)
        XCTAssertGreaterThan(stamped, 0, "the migration stamp must survive the launch that set it")

        // A second launch must inherit the FIRST launch's stamp, so the clock keeps running.
        let relaunched = UsageStore(logDir: { nil }, codexDir: { nil })
        XCTAssertEqual(relaunched.calibratedCapAt?.timeIntervalSince1970 ?? 0, stamped, accuracy: 0.001)
    }

    /// A manual cap is stated intent, not an inference from a reading, so it never expires —
    /// and it still outranks a learned cap that is still current.
    func testManualOverrideIsImmuneToExpiry() {
        let s = store(cap: 136_000_000, learnedAt: Date().addingTimeInterval(-46 * 3600))
        s.capOverride = 40_000_000
        XCTAssertEqual(s.effectiveCap, 40_000_000)
    }
}

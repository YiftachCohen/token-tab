// Rate-table coverage contract (Swift side).
//
// Mirror image of test/rates-coverage.test.mjs: the shared parity fixtures
// test/fixtures/parity/rates-all-models.json (Claude) and rates-all-models-codex.json
// (Codex) must together carry one record per (provider, model) this engine can price —
// every `rates`/`aliases` key under "claude" and every `openAIRates` key under "codex".
// Asserting set equality both ways per provider closes the failure loop across engines: a
// model added to Pricing.swift but not a fixture goes red here; a model in a fixture with
// no Swift rate behind it also goes red here. Combined with the JS test, a model added to
// one engine but not the other cannot ship green. Synthetic values only.

import XCTest
@testable import TokenTabCore

final class RatesCoverageTests: XCTestCase {

    /// The shared fixtures live at <repo>/test/fixtures/parity, OUTSIDE the SwiftPM
    /// package, so resolve them relative to this source file (same walk as ParityTests).
    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)   // .../app/Tests/TokenTabCoreTests/RatesCoverageTests.swift
            .deletingLastPathComponent()  // .../TokenTabCoreTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // .../app
            .deletingLastPathComponent()  // .../<repo>
            .appendingPathComponent("test/fixtures/parity")
    }

    private struct CoverageFixture: Decodable {
        struct Record: Decodable { let model: String; let provider: String? }
        let records: [Record]
    }

    private func loadFixture(_ name: String) throws -> CoverageFixture {
        let file = fixturesDir().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else {
            // STOP condition: the package was built from a relocated source tree.
            XCTFail("Coverage fixture not found at \(file.path) — cannot reach the shared test/fixtures/parity via #filePath. Do not hard-code an absolute path; report this.")
            return CoverageFixture(records: [])
        }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(CoverageFixture.self, from: data)
    }

    func testFixturesCoverSwiftRateTablesExactly() throws {
        let claudeFx = try loadFixture("rates-all-models.json")
        let codexFx = try loadFixture("rates-all-models-codex.json")

        let fixtureSet = Set(
            claudeFx.records.map { "claude:\($0.model)" } +
            codexFx.records.map { "\($0.provider ?? "claude"):\($0.model)" }
        )
        let tableSet = Set(
            Pricing.ratedModelIds.union(Pricing.aliasIds).map { "claude:\($0)" }
        ).union(Set(
            Pricing.openAIRatedModelIds.map { "codex:\($0)" }
        ))

        // A table key with no fixture record -> the cost of that model is never parity-checked.
        for id in tableSet {
            XCTAssertTrue(
                fixtureSet.contains(id),
                "app/Sources/TokenTabCore/Pricing.swift has a (provider, model) the coverage fixtures don't: \(id). Add a record for it to the matching test/fixtures/parity/rates-all-models*.json (1M input + 1M output; expected cost = input+output rate) — AND mirror the model in src/pricing.mjs.")
        }

        // A fixture record with no table entry -> a phantom model that prices as unknown.
        for id in fixtureSet {
            XCTAssertTrue(
                tableSet.contains(id),
                "a rates-all-models*.json fixture has a (provider, model) app/Sources/TokenTabCore/Pricing.swift doesn't: \(id). Either remove it or add the rate to the matching table in BOTH engines.")
        }
    }

    // Regression guard (design doc section 3): mirrors the JS
    // "known-unpriced Codex/legacy models are absent from the rate tables" test.
    func testKnownUnpricedModelsAreAbsent() {
        let claudeTable = Pricing.ratedModelIds.union(Pricing.aliasIds)
        let codexTable = Pricing.openAIRatedModelIds
        let shouldBeUnpriced = [
            "gpt-5.4-pro", "gpt-5.5-pro", "gpt-5.3-codex-spark", "gpt-5.4-codex", "codex-auto-review",
        ]
        for id in shouldBeUnpriced {
            XCTAssertFalse(claudeTable.contains(id), "\(id) must stay out of the Claude rate table")
            XCTAssertFalse(codexTable.contains(id), "\(id) must stay out of the Codex rate table")
        }
    }
}

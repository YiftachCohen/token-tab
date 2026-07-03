// Rate-table coverage contract (Swift side).
//
// Mirror image of test/rates-coverage.test.mjs: the shared parity fixture
// test/fixtures/parity/rates-all-models.json must carry one record per model this engine
// can price — every `rates` key and every `aliases` key. Asserting set equality both ways
// closes the failure loop across engines: a model added to Pricing.swift but not the
// fixture goes red here; a model in the fixture with no Swift rate behind it also goes
// red here. Combined with the JS test, a model added to one engine but not the other
// cannot ship green. Synthetic values only.

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
        struct Record: Decodable { let model: String }
        let records: [Record]
    }

    func testFixtureCoversSwiftRateTableExactly() throws {
        let file = fixturesDir().appendingPathComponent("rates-all-models.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            // STOP condition: the package was built from a relocated source tree.
            XCTFail("Coverage fixture not found at \(file.path) — cannot reach the shared test/fixtures/parity via #filePath. Do not hard-code an absolute path; report this.")
            return
        }

        let data = try Data(contentsOf: file)
        let fixture = try JSONDecoder().decode(CoverageFixture.self, from: data)
        let fixtureSet = Set(fixture.records.map { $0.model })
        let tableSet = Pricing.ratedModelIds.union(Pricing.aliasIds)

        // A table key with no fixture record -> the cost of that model is never parity-checked.
        for id in tableSet {
            XCTAssertTrue(
                fixtureSet.contains(id),
                "app/Sources/TokenTabCore/Pricing.swift has a model the coverage fixture doesn't: \(id). Add a record for it to test/fixtures/parity/rates-all-models.json (1M input + 1M output; expected cost = input+output rate) — AND mirror the model in src/pricing.mjs.")
        }

        // A fixture record with no table entry -> a phantom model that prices as unknown.
        for id in fixtureSet {
            XCTAssertTrue(
                tableSet.contains(id),
                "rates-all-models.json has a model app/Sources/TokenTabCore/Pricing.swift doesn't: \(id). Either remove it or add the rate to rates/aliases in BOTH engines.")
        }
    }
}

// Unit tests for the machine-local env-file parser (Config.parseEnvFile).
//
// These pin parity with the JS engine's loadLocalConfig() regex in token-tab.mjs: a
// CRLF (Windows) env file must yield clean values (no trailing \r that silently breaks
// Int(...) / mode switch / truthiness), one layer of matching quotes is stripped, only
// TOKENTAB_* and CLAUDE_CODE_USE_BEDROCK keys are honored, and the first value wins.
// Synthetic values only — no real secrets.

import XCTest
@testable import TokenTab

final class ConfigTests: XCTestCase {
    /// CRLF regression (the bug this fixes): a Windows-line-ending file must parse to clean
    /// values, not values with a trailing \r. `Int("400000000\r")` is nil, so a stray \r
    /// would silently drop the cap in the native app while the CLI honored it.
    func testCRLFValuesHaveNoCarriageReturn() {
        let values = Config.parseEnvFile("TOKENTAB_WINDOW_CAP=400000000\r\nTOKENTAB_MODE=bedrock\r\n")
        XCTAssertEqual(values["TOKENTAB_WINDOW_CAP"], "400000000", "CRLF value keeps no trailing \\r")
        XCTAssertEqual(values["TOKENTAB_MODE"], "bedrock", "CRLF mode value keeps no trailing \\r")
        XCTAssertEqual(Int(values["TOKENTAB_WINDOW_CAP"] ?? ""), 400000000, "the cleaned cap parses as an Int")
        for (_, v) in values {
            XCTAssertFalse(v.contains("\r"), "no parsed value may contain a carriage return")
        }
    }

    /// Quote stripping still works when the line has a CRLF ending (the \r is trimmed
    /// before the closing quote is examined, so one layer of quotes is still removed).
    func testQuoteStrippingWorksWithCRLF() {
        let values = Config.parseEnvFile("TOKENTAB_MODE=\"bedrock\"\r\n")
        XCTAssertEqual(values["TOKENTAB_MODE"], "bedrock", "one layer of matching quotes is stripped, CRLF and all")
    }

    /// Only TOKENTAB_* and CLAUDE_CODE_USE_BEDROCK keys are honored; anything else (e.g.
    /// PATH) is ignored, so an env file can never inject arbitrary process settings.
    func testKeyAllowlist() {
        let values = Config.parseEnvFile("PATH=/evil\nCLAUDE_CODE_USE_BEDROCK=1\nOTHER=x\n")
        XCTAssertEqual(values["CLAUDE_CODE_USE_BEDROCK"], "1", "the allowed Bedrock flag is parsed")
        XCTAssertNil(values["PATH"], "PATH is not an honored key")
        XCTAssertNil(values["OTHER"], "an arbitrary key is not honored")
        XCTAssertEqual(values.count, 1, "only the allowlisted key survives")
    }

    /// First value wins within a file (matches the JS `!(m[1] in process.env)` guard,
    /// applied per key as lines are read top-to-bottom).
    func testFirstValueWinsWithinAFile() {
        let values = Config.parseEnvFile("TOKENTAB_MODE=bedrock\nTOKENTAB_MODE=api\n")
        XCTAssertEqual(values["TOKENTAB_MODE"], "bedrock", "the first occurrence of a key wins, not the last")
    }
}

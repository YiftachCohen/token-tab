// Unit tests for Config.parseEnvFile — the KEY=VALUE env-file parser that mirrors the JS
// engine's loadLocalConfig() regex (token-tab.mjs). These pin the two parity gaps the parser
// fixes: CRLF line endings (the JS `\s*$` eats a trailing \r, so the Swift split must too) and
// the honored-key allowlist / quote-stripping / first-value-wins semantics. Parsing text
// directly (no $HOME touch) keeps these hermetic.

import XCTest
@testable import TokenTab

final class ConfigTests: XCTestCase {
    /// CRLF regression: a Windows-line-ending file must yield clean values with no trailing \r,
    /// so the cap parses as an Int and the mode matches a switch case (the whole point of the fix).
    func testParseEnvFileToleratesCRLF() {
        let values = Config.parseEnvFile("TOKENTAB_WINDOW_CAP=400000000\r\nTOKENTAB_MODE=bedrock\r\n")
        XCTAssertEqual(values["TOKENTAB_WINDOW_CAP"], "400000000", "CRLF value keeps no trailing \\r")
        XCTAssertEqual(values["TOKENTAB_MODE"], "bedrock", "CRLF value keeps no trailing \\r")
        XCTAssertNotNil(Int(values["TOKENTAB_WINDOW_CAP"] ?? ""), "the cleaned cap parses as an Int")
        XCTAssertFalse(values.values.contains(where: { $0.contains("\r") }), "no value carries a carriage return")
    }

    /// Quote-stripping still works when the line ends in CRLF (the \r must be trimmed before the
    /// closing quote is examined, or the suffix check fails and the quotes survive).
    func testParseEnvFileStripsQuotesWithCRLF() {
        let values = Config.parseEnvFile("TOKENTAB_MODE=\"bedrock\"\r\n")
        XCTAssertEqual(values["TOKENTAB_MODE"], "bedrock", "one layer of matching quotes is stripped after CRLF trim")
    }

    /// Only TOKENTAB_* and CLAUDE_CODE_USE_BEDROCK are honored — arbitrary env keys (PATH, OTHER)
    /// are ignored, so a stray config file can't inject unrelated settings.
    func testParseEnvFileHonorsKeyAllowlist() {
        let values = Config.parseEnvFile("PATH=/evil\nCLAUDE_CODE_USE_BEDROCK=1\nOTHER=x\n")
        XCTAssertEqual(values["CLAUDE_CODE_USE_BEDROCK"], "1", "the allowlisted Bedrock flag is kept")
        XCTAssertNil(values["PATH"], "PATH is not an honored key")
        XCTAssertNil(values["OTHER"], "an arbitrary key is not honored")
        XCTAssertEqual(values.count, 1, "only the one allowlisted key survives")
    }

    /// First value wins within a file (matches the JS `!(m[1] in process.env)` guard once the
    /// first assignment lands): a later duplicate line does not override the earlier one.
    func testParseEnvFileFirstValueWins() {
        let values = Config.parseEnvFile("TOKENTAB_MODE=bedrock\nTOKENTAB_MODE=api\n")
        XCTAssertEqual(values["TOKENTAB_MODE"], "bedrock", "the first assignment wins, the later duplicate is ignored")
    }
}

// The hero numeric face (Martian Mono) must actually bundle AND register — the whole
// "a number reads like a measurement" design rests on it. This pins that the font resource
// ships in the target and resolves by family name after registration; if the resource ever
// falls out of Package.swift, this fails loudly instead of the shipped app silently falling
// back to the system face.

import XCTest
import AppKit
@testable import TokenTab

final class FontLoaderTests: XCTestCase {
    func testMartianMonoRegistersAndResolvesByFamilyName() {
        FontLoader.registerBundledFonts()
        XCTAssertNotNil(NSFont(name: "Martian Mono", size: 24),
                        "Martian Mono must register from the bundled resource (Resources/Fonts/MartianMono.ttf)")
    }

    func testRegistrationIsIdempotent() {
        // A second call must not raise or duplicate-register.
        FontLoader.registerBundledFonts()
        FontLoader.registerBundledFonts()
        XCTAssertNotNil(NSFont(name: "Martian Mono", size: 12))
    }
}

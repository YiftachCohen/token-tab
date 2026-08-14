// The entire custom SwiftUI label must behave like the status button containing it. The hosted
// view otherwise wins AppKit hit-testing over the rings and figures, so only exposed padding
// sends the button action.

import XCTest
import AppKit
import SwiftUI
@testable import TokenTab

@MainActor
final class StatusItemInteractionTests: XCTestCase {
    func testHostedLabelDoesNotInterceptStatusButtonHitTesting() {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let host = MeasuringHostingView(rootView: Text("92%"))
        host.frame = button.bounds
        button.addSubview(host)

        for point in [NSPoint(x: 1, y: 11), NSPoint(x: 50, y: 11), NSPoint(x: 99, y: 11)] {
            XCTAssertTrue(button.hitTest(point) === button,
                          "clicks anywhere on the hosted label must reach the status button")
        }
    }
}

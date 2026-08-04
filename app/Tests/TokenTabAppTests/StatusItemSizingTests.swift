// The menu-bar item's WIDTH, which is a correctness property, not a cosmetic one.
//
// The status item gives the hosted label its width, so a `length` that lags the label's ideal
// width doesn't render as a narrow item — SwiftUI resolves the shortfall by truncating a figure,
// and "92%" becomes "92…". A menu-bar number that has quietly lost its percent sign is worse
// than no number, so the sizing path is pinned here:
//   • the ideal width is measured independently of the width the view currently has (otherwise
//     one missed update can confirm a too-narrow item forever — the released 0.3.2 sat at a
//     one-pair 56pt while rendering a two-pair label), and
//   • a size change in the SwiftUI content is itself the signal to re-measure, so no store
//     publish has to arrive for the item to catch up.

import XCTest
import AppKit
import SwiftUI
@testable import TokenTab

@MainActor
private final class WidthBox: ObservableObject {
    @Published var text = "92%"
}

private struct WidthProbeView: View {
    @ObservedObject var box: WidthBox
    var body: some View {
        Text(box.text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 5)
            .fixedSize()
    }
}

@MainActor
final class StatusItemSizingTests: XCTestCase {

    /// The reported ideal width must be the content's own, even while the view is installed in
    /// a container narrower than that — this is what lets a stuck-narrow item recover.
    func testIdealWidthIgnoresATooNarrowContainer() {
        let box = WidthBox()
        let host = MeasuringHostingView(rootView: WidthProbeView(box: box))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 22))
        container.addSubview(host)
        let trailing = host.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        trailing.priority = .defaultLow
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailing,
            host.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let ideal = host.idealWidth
        XCTAssertGreaterThan(ideal, 20, "the container is deliberately far too narrow")

        // Squeeze it further; the ideal width is a property of the content, not of the frame.
        container.setFrameSize(NSSize(width: 10, height: 22))
        container.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.idealWidth, ideal, accuracy: 0.5,
                       "a too-narrow container must not be able to confirm itself")
    }

    /// Growing the figure must re-drive the item's length WITHOUT waiting for a store publish:
    /// the SwiftUI content invalidating its own size is the trigger.
    func testContentGrowthNotifiesAndWidens() {
        let box = WidthBox()
        let host = MeasuringHostingView(rootView: WidthProbeView(box: box))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        host.layoutSubtreeIfNeeded()
        let narrow = host.idealWidth

        var notified = 0
        host.onIntrinsicSizeInvalidated = { notified += 1 }

        box.text = "100% Cdx"
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(notified, 0, "a content size change must announce itself")
        XCTAssertGreaterThan(host.idealWidth, narrow)
    }
}

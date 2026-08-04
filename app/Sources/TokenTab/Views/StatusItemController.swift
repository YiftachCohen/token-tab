// Token Tab — the menu-bar status item, owned directly instead of via SwiftUI's MenuBarExtra.
//
// WHY THIS EXISTS: MenuBarExtra renders only ONE Text and ONE Image in its label. The
// two-provider label (a ring + figure per provider) was silently truncated to the first pair
// — the status item didn't even size for the second one — and flattening the HStack changed
// nothing. It's the same ceiling that made a custom SwiftUI Shape invisible there (see the
// MenuBarLabel header). Hosting the SAME `MenuBarLabel` in an NSHostingView inside an
// NSStatusItem's button lifts it: the label is a real view tree again, so it renders whatever
// we compose, and the rings can go back to being drawn however we like.
//
// The dropdown keeps its old presentation: an NSPopover with `.transient` behavior is what
// `.menuBarExtraStyle(.window)` was, and it hosts the SAME unmodified `DropdownView`.
//
// Trust posture is unchanged — this is AppKit windowing only. No network, no subprocess, and
// nothing here reads a log file (the store still does all reading, under the same grant).

import SwiftUI
import AppKit
import Combine

/// Whether the dropdown is open. The status item paints the system selection fill behind the
/// label while it is, so the figures need to invert — AppKit does that automatically only for
/// a plain template image, which a hosted SwiftUI label is not.
@MainActor
final class MenuSelectionState: ObservableObject {
    @Published var isOpen = false
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let access: AccessManager
    private let helper: LiveHelperManager
    private let selection = MenuSelectionState()

    private var statusItem: NSStatusItem?
    private var hostingView: MeasuringHostingView<MenuBarLabelHost>?
    private var popover: NSPopover?
    private var storeObserver: AnyCancellable?
    /// One pending re-measure at a time: both triggers (a store publish and a SwiftUI size
    /// invalidation) can fire several times per update, and re-measuring resizes the button,
    /// which can invalidate again. Coalescing keeps that from becoming a treadmill.
    private var lengthUpdateScheduled = false

    init(store: UsageStore, access: AccessManager, helper: LiveHelperManager) {
        self.store = store
        self.access = access
        self.helper = helper
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        let host = MeasuringHostingView(rootView: MenuBarLabelHost(store: store, selection: selection))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        // Leading + centerY are required; trailing is not. A required trailing pin makes the
        // BUTTON's width authoritative over the label's, so any moment the item is narrower
        // than the reading — a length update that hasn't landed yet — SwiftUI resolves it by
        // truncating a figure ("92%" → "92…"). At low priority the label keeps its own width
        // and the item catches up, which is the only correct direction for a status item.
        let trailing = host.trailingAnchor.constraint(equalTo: button.trailingAnchor)
        trailing.priority = .defaultLow
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            trailing,
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        button.target = self
        button.action = #selector(togglePopover)

        statusItem = item
        hostingView = host

        // `variableLength` alone leaves the button sizing to an intrinsic size the hosted view
        // reports a beat late, which shows up as a clipped or zero-width item on first paint.
        // Driving `length` from the hosted view's ideal width makes it deterministic.
        //
        // It has to be re-driven whenever the label's ideal width changes ("9%" → "100%", a
        // second provider appearing, a Codex % lapsing into a token count). A store publish is
        // NOT a reliable signal for that: it fires before SwiftUI has applied the update, and
        // any publish that gets missed leaves the item stuck narrow indefinitely — the released
        // 0.3.2 sat at a one-pair 56pt while rendering a two-pair label, which is what the
        // ellipsis in the bar actually was. `MeasuringHostingView` reports the moment SwiftUI
        // invalidates its own intrinsic size instead, so the trigger is the size change itself.
        host.onIntrinsicSizeInvalidated = { [weak self] in
            self?.scheduleLengthUpdate()
        }
        updateLength()
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleLengthUpdate() }
        }
    }

    /// Re-measure on the next main-actor turn — after SwiftUI has applied whatever change
    /// triggered this, and never in the middle of the layout pass that reported it.
    private func scheduleLengthUpdate() {
        guard !lengthUpdateScheduled else { return }
        lengthUpdateScheduled = true
        Task { @MainActor in
            self.lengthUpdateScheduled = false
            self.updateLength()
        }
    }

    private func updateLength() {
        guard let item = statusItem, let host = hostingView else { return }
        host.layoutSubtreeIfNeeded()
        // The hosted view's OWN ideal width, never `fittingSize` on the installed view: fitting
        // size is resolved against the constraints it currently lives under, so measuring it
        // while the button is too narrow risks confirming the too-narrow width forever.
        let width = ceil(host.idealWidth)
        guard width > 0, abs(item.length - width) > 0.5 else { return }
        item.length = width
    }

    @objc private func togglePopover() {
        if let open = popover, open.isShown {
            open.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        let p = popover ?? makePopover()
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        selection.isOpen = true
        button.highlight(true)
    }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient      // click-outside dismisses, as MenuBarExtra's window did
        p.animates = false           // the bar is a glance surface; a fade reads as lag
        p.contentViewController = NSHostingController(
            rootView: DropdownView(store: store, access: access, helper: helper))
        p.delegate = self
        popover = p
        return p
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.selection.isOpen = false
            self.statusItem?.button?.highlight(false)
        }
    }
}

/// An `NSHostingView` that says when its SwiftUI content changes size, and reports that size
/// without consulting the constraints it is installed under.
///
/// Both matter for a status item: the item's `length` is what gives the label its width, so the
/// label's ideal width has to reach `length` — never the other way round. Reading `fittingSize`
/// of the installed view can hand back a width already limited by the item, and a status item
/// that is one figure too narrow doesn't look narrow, it looks like a truncated number.
final class MeasuringHostingView<Content: View>: NSHostingView<Content> {
    /// Called when SwiftUI invalidates the hosted content's intrinsic size — i.e. exactly when
    /// the label's ideal width may have changed, regardless of what published it.
    var onIntrinsicSizeInvalidated: (() -> Void)?

    /// The width the content wants, independent of the width it currently has.
    var idealWidth: CGFloat {
        let intrinsic = intrinsicContentSize.width
        return intrinsic > 0 ? intrinsic : fittingSize.width
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }
}

/// The hosted label. It observes the store itself (an NSHostingView's root view is not in a
/// SwiftUI scene, so nothing else would re-render it) and adds the status item's internal
/// horizontal padding, which the button no longer supplies for a custom subview.
///
/// `.fixedSize()` is load-bearing: without it a menu-bar figure is a truncatable string, so any
/// width shortfall — even a transient one, between a figure growing and the item resizing —
/// renders as "92…" rather than as a slightly clipped label. A number in the menu bar is either
/// readable or it is misinformation; it must never quietly lose a digit or a percent sign.
struct MenuBarLabelHost: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var selection: MenuSelectionState

    var body: some View {
        MenuBarLabel(snapshot: store.snapshot, menuMetric: store.menuMetric,
                     scope: store.menuBarScope, now: store.clock, selected: selection.isOpen)
            .padding(.horizontal, 5)
            .fixedSize()
    }
}

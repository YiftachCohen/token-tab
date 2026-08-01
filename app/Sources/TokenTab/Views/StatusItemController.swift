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
    private var hostingView: NSHostingView<MenuBarLabelHost>?
    private var popover: NSPopover?
    private var storeObserver: AnyCancellable?

    init(store: UsageStore, access: AccessManager, helper: LiveHelperManager) {
        self.store = store
        self.access = access
        self.helper = helper
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        let host = NSHostingView(rootView: MenuBarLabelHost(store: store, selection: selection))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        button.target = self
        button.action = #selector(togglePopover)

        statusItem = item
        hostingView = host

        // `variableLength` alone leaves the button sizing to an intrinsic size the hosted view
        // reports a beat late, which shows up as a clipped or zero-width item on first paint.
        // Driving `length` from the hosted view's fitting width makes it deterministic, and
        // re-driving it on every store change keeps it correct when the figures change width
        // (e.g. "9%" → "100%", or a provider appearing and adding a second pair).
        updateLength()
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateLength() }
        }
    }

    private func updateLength() {
        guard let item = statusItem, let host = hostingView else { return }
        host.layoutSubtreeIfNeeded()
        let width = ceil(host.fittingSize.width)
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

/// The hosted label. It observes the store itself (an NSHostingView's root view is not in a
/// SwiftUI scene, so nothing else would re-render it) and adds the status item's internal
/// horizontal padding, which the button no longer supplies for a custom subview.
struct MenuBarLabelHost: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var selection: MenuSelectionState

    var body: some View {
        MenuBarLabel(snapshot: store.snapshot, menuMetric: store.menuMetric,
                     scope: store.menuBarScope, now: store.clock, selected: selection.isOpen)
            .padding(.horizontal, 5)
    }
}

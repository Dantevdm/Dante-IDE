import AppKit
import SwiftUI

extension View {
    /// Runs `action` when the middle mouse button is released over this view, as browsers
    /// close a tab. The view underneath never takes clicks: a window-wide monitor checks the
    /// click's position against it, so taps, hovers and drags still reach the tab.
    func onMiddleClick(perform action: @escaping @MainActor () -> Void) -> some View {
        background(MiddleClickSpot(action: action))
    }
}

private struct MiddleClickSpot: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak coordinator] event in
            guard event.buttonNumber == 2 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let coordinator, let view = coordinator.view, let window = view.window,
                      event.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return false }
                coordinator.action?()
                return true
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var action: (@MainActor () -> Void)?
        var monitor: Any?
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

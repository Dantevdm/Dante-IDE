import AppKit
import SwiftUI

extension View {
    /// Zooms with a mouse's scroll wheel, or ⌘ and a trackpad's two-finger scroll, over this
    /// view: `zoom` gets the factor and the pointer's place in the view (top-left origin).
    /// A trackpad's plain scrolling still pans, so the two never fight.
    func onPointerZoom(perform zoom: @escaping @MainActor (CGFloat, CGPoint) -> Void) -> some View {
        background(PointerZoomSpot(zoom: zoom))
    }
}

private struct PointerZoomSpot: NSViewRepresentable {
    let zoom: @MainActor (CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedPassThrough()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let coordinator, let view = coordinator.view, let window = view.window,
                      event.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return false }
                guard let factor = PointerZoom.factor(for: event) else { return false }
                coordinator.zoom?(factor, point)
                return true
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.zoom = zoom
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var zoom: (@MainActor (CGFloat, CGPoint) -> Void)?
        var monitor: Any?
    }

    private final class FlippedPassThrough: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

enum PointerZoom {
    /// How much one wheel event zooms by, or nil when it should scroll instead: a trackpad's
    /// (precise) scrolling without ⌘, momentum after a flick, or no vertical movement.
    @MainActor
    static func factor(for event: NSEvent) -> CGFloat? {
        let precise = event.hasPreciseScrollingDeltas
        guard !precise || event.modifierFlags.contains(.command) else { return nil }
        guard event.momentumPhase.isEmpty else { return nil }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return nil }
        // A wheel click is about one line; a trackpad gives many small points.
        let step = precise ? delta / 120 : delta / 10
        return CGFloat(exp(Double(max(-0.5, min(0.5, step)))))
    }

    /// The scroll offset that keeps the content under `point` (in the viewport) still while
    /// the zoom goes from `old` to `new`.
    static func offset(keeping point: CGPoint, at offset: CGPoint, from old: CGFloat, to new: CGFloat) -> CGPoint {
        let ratio = new / old
        return CGPoint(x: max(0, (offset.x + point.x) * ratio - point.x), y: max(0, (offset.y + point.y) * ratio - point.y))
    }
}

/// A picture that zooms: the scroll wheel or a pinch zooms around the pointer, trackpad
/// scrolling pans, and the corner has −, the percentage (back to fit) and +. The content is
/// laid out at its own size and scaled as vectors, so text and lines stay sharp at any zoom.
struct ZoomablePicture<Content: View>: View {
    @Environment(\.theme) private var theme
    var minZoom: CGFloat = 0.2
    var maxZoom: CGFloat = 4
    /// Fitting never enlarges past this (100% in a page; a sheet of its own allows more).
    var largestFit: CGFloat = 1
    @ViewBuilder let content: Content
    @State private var zoom: CGFloat = 1
    @State private var natural: CGSize = .zero
    @State private var viewport: CGSize = .zero
    @State private var offset: CGPoint = .zero
    @State private var position = ScrollPosition()
    @State private var fitted = false
    @State private var pinchStart: CGFloat?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    natural = size
                    if !fitted, viewport != .zero { fit(); fitted = true }
                }
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: natural.width * zoom, height: natural.height * zoom, alignment: .topLeading)
                // Centred while it's smaller than the view.
                .frame(minWidth: viewport.width, minHeight: viewport.height)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in
            viewport = size
            if !fitted, natural != .zero { fit(); fitted = true }
        }
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, point in offset = point }
        .onPointerZoom { factor, point in zoom(to: zoom * factor, around: point) }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = zoom }
                zoom(to: (pinchStart ?? 1) * value.magnification, around: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
            }
            .onEnded { _ in pinchStart = nil })
        .overlay(alignment: .bottomTrailing) { controls.padding(10) }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "minus.magnifyingglass", label: "Zoom out", size: 12) { zoom(to: zoom / 1.25, around: center) }
            Button { fit() } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.dante(size: 11.5, weight: .medium).monospacedDigit())
                    .frame(minWidth: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text2.color)
            .help("Fit the view")
            IconButton(symbol: "plus.magnifyingglass", label: "Zoom in", size: 12) { zoom(to: zoom * 1.25, around: center) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color))
        .help("Scroll the mouse wheel, pinch, or hold ⌘ and scroll to zoom")
    }

    private var center: CGPoint { CGPoint(x: viewport.width / 2, y: viewport.height / 2) }

    private func zoom(to value: CGFloat, around point: CGPoint) {
        let new = min(maxZoom, max(minZoom, value))
        guard new != zoom else { return }
        let target = PointerZoom.offset(keeping: point, at: offset, from: zoom, to: new)
        zoom = new
        position.scrollTo(point: target)
    }

    /// The whole picture in view, never above `largestFit`.
    private func fit() {
        guard natural.width > 0, natural.height > 0, viewport.width > 0 else { return }
        // A little margin, so the picture doesn't touch the edges.
        let room = CGSize(width: viewport.width - 48, height: viewport.height - 64)
        zoom = max(minZoom, min(largestFit, room.width / natural.width, max(0.5, room.height / natural.height)))
        position.scrollTo(point: .zero)
    }
}

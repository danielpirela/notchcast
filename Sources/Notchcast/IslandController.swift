import AppKit
import SwiftUI

enum IslandVisual: String { case closed, compact, expanded }

/// Where the island sits: hugging the notch, or a pill at the top center on screens without one.
struct IslandGeometry {
    var screenFrame: CGRect
    var hasNotch: Bool
    var notch: CGSize

    static let ear: CGFloat = 72

    static func current() -> IslandGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return IslandGeometry(screenFrame: screen.frame, hasNotch: true, notch: CGSize(width: width, height: top))
        }
        return IslandGeometry(screenFrame: screen.frame, hasNotch: false, notch: CGSize(width: 0, height: 34))
    }

    var headerHeight: CGFloat { notch.height }
    var topInset: CGFloat { hasNotch ? 0 : 6 }

    func size(for visual: IslandVisual) -> CGSize {
        switch visual {
        case .closed:
            return hasNotch ? notch : CGSize(width: 110, height: 30)
        case .compact:
            return hasNotch ? CGSize(width: notch.width + Self.ear * 2, height: notch.height) : CGSize(width: 210, height: 34)
        case .expanded:
            return CGSize(width: max(notch.width + Self.ear * 2, 470), height: 310)
        }
    }

    func cornerRadii(for visual: IslandVisual) -> (top: CGFloat, bottom: CGFloat) {
        let bottom: CGFloat
        switch visual {
        case .closed: bottom = hasNotch ? 10 : 15
        case .compact: bottom = hasNotch ? 14 : 17
        case .expanded: bottom = 28
        }
        return (hasNotch ? 0 : bottom, bottom)
    }

    func panelFrame(for visual: IslandVisual) -> CGRect {
        let size = size(for: visual)
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - topInset - size.height,
                      width: size.width, height: size.height)
    }
}

struct IslandActions {
    var tap: () -> Void
    var longPress: () -> Void
    var togglePause: () -> Void
    var stop: () -> Void
    var repeatLast: () -> Void
    var close: () -> Void
}

/// Owns the borderless panel and the island's open/closed state.
@MainActor
final class IslandController: ObservableObject {
    enum Mode: String { case hidden, compact, expanded }

    @Published private(set) var mode: Mode = .hidden
    @Published private(set) var visual: IslandVisual = .closed
    @Published private(set) var geometry = IslandGeometry.current()

    private var panel: IslandPanel!
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    private let settle: TimeInterval = 0.5

    init(speech: SpeechController, actions: IslandActions) {
        let view = IslandView(island: self, speech: speech, actions: actions)
        panel = IslandPanel(content: view)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    var isPanelVisible: Bool { panel.isVisible }
    var panelFrame: CGRect { panel.frame }

    func show() {
        guard mode == .hidden else { return }
        present(at: .compact)
        mode = .compact
        animate(to: .compact)
    }

    func expand() {
        if mode == .hidden { present(at: .expanded) }
        mode = .expanded
        panel.setFrame(geometry.panelFrame(for: .expanded), display: true)
        animate(to: .expanded)
    }

    func collapse() {
        guard mode == .expanded else { return }
        mode = .compact
        animate(to: .compact)
        after(settle) { [weak self] in
            guard let self, self.mode == .compact else { return }
            self.panel.setFrame(self.geometry.panelFrame(for: .compact), display: true)
        }
    }

    func hide() {
        guard mode != .hidden else { return }
        mode = .hidden
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { visual = .closed }
        after(settle) { [weak self] in
            guard let self, self.mode == .hidden else { return }
            self.panel.orderOut(nil)
        }
    }

    private func present(at visual: IslandVisual) {
        geometry = .current()
        self.visual = .closed
        panel.setFrame(geometry.panelFrame(for: visual), display: true)
        panel.orderFrontRegardless()
    }

    private func animate(to target: IslandVisual) {
        // Next runloop pass so the panel is on screen in its closed shape before springing open.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(self.spring) { self.visual = target }
            }
        }
    }

    private func relayout() {
        geometry = .current()
        guard mode != .hidden else { return }
        panel.setFrame(geometry.panelFrame(for: mode == .expanded ? .expanded : .compact), display: true)
    }

    private func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }
}

/// Borderless, non-activating panel that can sit over the menu bar.
final class IslandPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none

        let host = FirstClickHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Allow the window to overlap the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

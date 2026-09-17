import AppKit
import SwiftUI

/// Thin, self-hiding scrollbars for the main window's content.
///
/// SwiftUI's `HostingScrollView` inherits the system scroller style, and when a
/// mouse is attached macOS's "Automatic" setting resolves to the *legacy*
/// scroller: a 17pt-wide bar with an 11pt knob that never hides and takes
/// layout width. Forcing overlay with a small control size gives a 15pt bar
/// with a 4pt knob that fades out when idle. Measured, not estimated:
///
///     before   style=legacy   controlSize=regular   view=17pt   knob=11pt
///     after    style=overlay  controlSize=small     view=15pt   knob=4pt
///
/// There is no SwiftUI API for this, so it goes through the underlying
/// `NSScrollView`. Attach it as the *background of the scroll view's content*,
/// not of the `ScrollView` itself, so `enclosingScrollView` resolves to the
/// intended scroller rather than an ancestor.
///
/// Technique from the Don't Miss agent's write-up, which established the
/// reassert-on-change part by measurement; adapted here with a preference check
/// and a safer threading contract.
extension View {
    /// Applies to the content *inside* a `ScrollView`, e.g.
    /// `ScrollView { content.thinScrollers() }`.
    func thinScrollers() -> some View {
        background(ThinScrollerBridge())
    }
}

private struct ThinScrollerBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        // Re-asserted on every SwiftUI update as well as via the observation
        // below: the Dashboard re-renders on each stats poll, which is exactly
        // when AppKit has been seen to put the style back.
        nsView.attachAndEnforce()
    }

    final class BridgeView: NSView {
        private weak var scrollView: NSScrollView?
        private var styleObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachAndEnforce()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attachAndEnforce()
        }

        /// Someone who sets "Show scroll bars: Always" in System Settings has
        /// asked for persistent scrollbars, often for accessibility. Overriding
        /// that would be wrong. The legacy scroller we are replacing comes from
        /// "Automatic" resolving against an attached mouse, which is a default
        /// rather than a decision.
        private var userWantsPersistentScrollbars: Bool {
            UserDefaults.standard.string(forKey: "AppleShowScrollBars") == "Always"
        }

        func attachAndEnforce() {
            guard !userWantsPersistentScrollbars, let enclosing = enclosingScrollView else { return }
            if scrollView !== enclosing {
                scrollView = enclosing
                styleObservation = enclosing.observe(\.scrollerStyle, options: [.new]) { [weak self] _, change in
                    // Ignore our own assignment; only react to it being put back.
                    guard change.newValue != .overlay else { return }
                    // KVO delivers on whichever thread mutated the property.
                    // AppKit views are main-thread only, so hop rather than
                    // assume — `assumeIsolated` off-main is a crash, not a warning.
                    if Thread.isMainThread {
                        MainActor.assumeIsolated { self?.enforce() }
                    } else {
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.enforce() } }
                    }
                }
            }
            enforce()
        }

        private func enforce() {
            guard let scrollView else { return }
            if scrollView.scrollerStyle != .overlay {
                scrollView.scrollerStyle = .overlay
            }
            if scrollView.verticalScroller?.controlSize != .small {
                scrollView.verticalScroller?.controlSize = .small
            }
        }
    }
}

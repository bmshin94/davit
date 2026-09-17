import SwiftUI

/// Tracks whether any main window is on screen.
///
/// Two things hang off that. The visible one: the app switches between a
/// regular app (Dock icon, ⌘Tab) while a window is open and a menu-bar-only
/// accessory when the last one closes — standard behavior for a menu-bar
/// utility, unless the user opts out. The invisible one: a closed window keeps
/// its SwiftUI tree alive, so every poll re-renders and AppKit re-lays out the
/// whole dashboard for an audience of nobody (measurably ~30% CPU with a few
/// containers running). `MainWindow` drops its content while this is false and
/// `AppState` pauses the stats poll.
@MainActor
final class WindowPresence: ObservableObject {
    static let shared = WindowPresence()
    @Published private(set) var hasVisibleWindow = true
    private var observers: [NSObjectProtocol] = []
    /// Set once the scene's window has actually appeared. Before that the app
    /// stays optimistic: at launch an activation notification can land while
    /// the window is still being made, and treating that as "no window" hides
    /// the content and drops the app to accessory before it ever shows one.
    private var sawWindow = false

    var keepInDock: Bool {
        UserDefaults.standard.bool(forKey: "keepInDock")
    }

    func start() {
        guard observers.isEmpty else { return }
        let events: [Notification.Name] = [
            NSWindow.willCloseNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        for event in events {
            observers.append(NotificationCenter.default.addObserver(
                forName: event, object: nil, queue: .main
            ) { note in
                // willClose fires while the window is still listed as visible.
                let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                Task { @MainActor in WindowPresence.shared.update(ignoring: closing) }
            })
        }
    }

    private func update(ignoring closing: NSWindow?) {
        let visible = NSApp.windows.contains {
            $0 !== closing && $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized
        }
        if visible { sawWindow = true }
        guard sawWindow else { return }
        if hasVisibleWindow != visible { hasVisibleWindow = visible }
        if visible {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        } else if !keepInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct ContainerStackApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // A single reopenable window (WindowGroup windows die on close and the
        // menu bar extra could no longer reopen them).
        Window("Davit", id: "main") {
            MainWindow()
                .environmentObject(state)
                .frame(minWidth: 940, minHeight: 560)
                .task {
                    WindowPresence.shared.start()
                    state.startPolling()
                }
                // Deep links: davit://container/<id> opens that container's
                // detail (Overview). Lets other apps refer to a container and
                // reveal it here.
                .onOpenURL { url in
                    state.handleDeepLink(url)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1180, height: 720)
        // Always present the window on launch: without this, state restoration
        // remembers a closed window and the app launches windowless (which also
        // hangs headless --snapshot/--probe runs waiting for MainWindow).
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await state.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Search…") { state.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
        } label: {
            MenuBarIcon()
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

/// The menu bar icon exists from launch even when no window does, so it also
/// hosts the harness fallback: headless launches of the bundled app sometimes
/// never materialize the Window scene — if no window appears, open it.
struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow

    /// The bundled template glyph (three container outlines). Falls back to an
    /// SF Symbol in dev/harness runs where the bundle has no Resources.
    private static let templateImage: NSImage = {
        let image = NSImage(named: "DavitTemplate")
            ?? NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Davit")!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .task {
                guard SnapshotDriver.isHarnessRun else { return }
                try? await Task.sleep(for: .seconds(2))
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    FileHandle.standardError.write(Data("harness: window missing after launch, forcing open\n".utf8))
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

// MARK: - Menu bar extra

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch state.systemState {
            case .running:
                // Menus tint images monochrome, so a green dot would just look
                // like a grey ball — use symbols that read in grey instead.
                Label("Services running", systemImage: "checkmark.circle.fill")
                Button("Stop Services") { state.toggleSystem() }
            case .stopped:
                Label("Services stopped", systemImage: "stop.circle")
                Button("Start Services") { state.toggleSystem() }
            case .unknown:
                Label("Status unknown", systemImage: "questionmark.circle")
            }

            Divider()

            if state.runningContainers.isEmpty {
                Text("No running containers")
            } else {
                Text("Running Containers")
                ForEach(state.runningContainers) { c in
                    Menu(c.id) {
                        Button("Stop") { state.stopContainer(c) }
                        Button("Restart") { state.restartContainer(c) }
                        Button("Open Terminal") { TerminalLauncher.openShell(containerID: c.id) }
                    }
                }
            }

            Divider()

            Button("Open Davit") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit Davit") { NSApp.terminate(nil) }
        }
    }
}

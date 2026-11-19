import AppKit
import StehaufCore
import SwiftUI

/// Kleines schwebendes Fenster für die Ankündigung. Es nimmt dem aktiven
/// Programm nicht den Fokus weg und bleibt auch im Fokus-Modus sichtbar,
/// anders als eine normale Mitteilung.
@MainActor
final class CountdownPanelController {
    private unowned let coordinator: Coordinator
    private var panel: NSPanel?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    func update() {
        let state = coordinator.state
        let wanted = state.isAnnouncing || state.isMoving
        if wanted {
            show()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let host = NSHostingView(rootView: CountdownView(coordinator: coordinator))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }
}

struct CountdownView: View {
    @ObservedObject var coordinator: Coordinator

    private var state: EngineState { coordinator.state }
    private var goingUp: Bool { state.phase == .announcingUp || state.phase == .movingUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.isMoving {
                Text(goingUp ? "Tisch fährt hoch" : "Tisch fährt runter")
                    .font(.headline)
                Button("Stopp") { coordinator.stopDesk() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            } else {
                Text(goingUp ? "Tisch fährt gleich hoch" : "Tisch fährt gleich runter")
                    .font(.headline)
                if state.waitingForPresence {
                    Text("Wartet auf dich. Bewege die Maus, dann geht es los.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(Format.countdown(to: state.deadline, now: coordinator.now))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                HStack {
                    Button("Jetzt") { coordinator.perform(.goNow) }
                    Button(goingUp ? "Später" : "Weiter stehen") { coordinator.perform(.snooze) }
                    Button("Bin im Meeting") {
                        coordinator.feedback("missed-meeting")
                        coordinator.perform(.inMeeting)
                    }
                    Button("Heute nicht") { coordinator.perform(.notToday) }
                }
            }
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
    }
}

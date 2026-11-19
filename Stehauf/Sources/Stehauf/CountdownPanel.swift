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
            contentRect: NSRect(origin: .zero, size: CountdownView.size),
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
        let hosting = NSHostingView(rootView: CountdownView(coordinator: coordinator))
        // Sonst erzwingt die SwiftUI-Größe zusätzlich die Höhe der Titelleiste.
        hosting.sizingOptions = []
        panel.contentView = hosting
        // Mit fullSizeContentView reicht der Inhalt bis unter die (unsichtbare)
        // Titelleiste. Deshalb den ganzen Rahmen setzen, sonst bleibt unten ein
        // leerer Streifen in Höhe der Titelleiste.
        panel.setFrame(NSRect(origin: .zero, size: CountdownView.size), display: false)
        return panel
    }
}

struct CountdownView: View {
    /// Feste Größe, damit das Fenster bei wechselndem Inhalt nichts abschneidet.
    static let size = CGSize(width: 420, height: 132)

    @ObservedObject var coordinator: Coordinator

    private var state: EngineState { coordinator.state }
    private var goingUp: Bool { state.phase == .announcingUp || state.phase == .movingUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.isMoving {
                Text(goingUp ? "Tisch fährt hoch" : "Tisch fährt runter")
                    .font(.headline)
                Text(Format.height(coordinator.signals.deskHeightMM))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
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
        .frame(width: CountdownView.size.width, height: CountdownView.size.height, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

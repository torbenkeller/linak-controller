import AppKit
import ServiceManagement
import StehaufCore
import SwiftUI

@MainActor
final class StatusWindowController {
    private unowned let coordinator: Coordinator
    private var window: NSWindow?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: StatusView(coordinator: coordinator))
            let created = NSWindow(contentViewController: host)
            created.title = "Stehauf"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Statusanzeige und Einstellungen in einem Fenster.
struct StatusView: View {
    @ObservedObject var coordinator: Coordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Was die App gerade erkennt") {
                ForEach(coordinator.statusLines(), id: \.self) { line in
                    Text(line)
                }
            }

            Section("Erkennung war falsch") {
                Text("Ein Klick speichert alle aktuellen Messwerte mit einer Markierung im Protokoll.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(FeedbackMenu.entries, id: \.kind) { entry in
                    Button(entry.title) { coordinator.feedback(entry.kind) }
                }
                Button("Notiz …") { FeedbackMenu.askForNote(coordinator: coordinator) }
            }

            Section("Rhythmus") {
                Stepper("Sitzen: \(Int(coordinator.config.sitMinutes)) min",
                        value: $coordinator.config.sitMinutes, in: 5...180, step: 5)
                Stepper("Stehen: \(Int(coordinator.config.standMinutes)) min",
                        value: $coordinator.config.standMinutes, in: 5...120, step: 5)
                Toggle("Nach der Stehphase automatisch runterfahren", isOn: $coordinator.config.autoDown)
            }

            Section("Tisch") {
                LabeledContent("Sitzhöhe: \(Format.height(coordinator.config.sitHeightMM))") {
                    Button("Aktuelle Höhe übernehmen") { coordinator.useCurrentHeight(for: .down) }
                }
                LabeledContent("Stehhöhe: \(Format.height(coordinator.config.standHeightMM))") {
                    Button("Aktuelle Höhe übernehmen") { coordinator.useCurrentHeight(for: .up) }
                }
                HStack {
                    Button("Hochfahren") { coordinator.perform(.raise) }
                    Button("Runterfahren") { coordinator.perform(.lower) }
                    Button("Stopp") { coordinator.stopDesk() }
                    Spacer()
                    Button("Tisch vergessen") { coordinator.forgetDesk() }
                }
                .disabled(!coordinator.signals.deskConnected && coordinator.config.deskIdentifier == nil)
            }

            Section("Ankündigung") {
                Stepper("Countdown: \(Int(coordinator.config.countdownSeconds)) s",
                        value: $coordinator.config.countdownSeconds, in: 10...300, step: 10)
                Toggle("Tisch stupst kurz zur Ankündigung", isOn: $coordinator.config.nudgeEnabled)
                Toggle("Ton abspielen", isOn: $coordinator.config.soundEnabled)
            }

            Section("Meetings") {
                Toggle("Kalender berücksichtigen", isOn: $coordinator.config.useCalendar)
                if coordinator.config.useCalendar && !coordinator.calendarAuthorized {
                    LabeledContent("Kalenderzugriff fehlt") {
                        Button("Zugriff erlauben") { coordinator.requestCalendarAccess() }
                    }
                }
            }

            Section("App") {
                Picker("Icon in der Menüleiste", selection: $coordinator.config.menuBarMode) {
                    Text("Nur wenn etwas ansteht").tag(MenuBarMode.whenRelevant)
                    Text("Immer").tag(MenuBarMode.always)
                }
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                HStack {
                    Button("Protokoll-Ordner öffnen") { coordinator.openLogFolder() }
                    Button("Konfigurationsdatei öffnen") { coordinator.openConfigFile() }
                    Button("Neu laden") { coordinator.reloadConfig() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 760)
    }
}

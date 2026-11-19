import AppKit
import StehaufCore

/// Menüeintrag, der beim Anklicken eine Closure ausführt.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("nicht unterstützt")
    }

    @objc private func fire() {
        handler()
    }
}

/// Das Icon in der Menüleiste. Im Modus `whenRelevant` ist es nur während
/// Ankündigung, Fahrt und Stehphase sichtbar.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private unowned let coordinator: Coordinator
    private var shown = ""

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = false
    }

    func update() {
        let state = coordinator.state
        let standing = coordinator.signals.deskConnected && coordinator.assessment.posture == .standing
        let relevant = state.isAnnouncing || state.isMoving || standing
        let visible = coordinator.config.menuBarMode == .always || relevant
        if item.isVisible != visible { item.isVisible = visible }
        guard visible, let button = item.button else { return }

        var symbol = "chair"
        var title = ""
        switch state.phase {
        case .announcingUp, .announcingDown:
            symbol = state.phase == .announcingUp ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
            title = state.waitingForPresence ? "wartet" : Format.countdown(to: state.deadline, now: coordinator.now)
        case .movingUp:
            symbol = "arrow.up"
        case .movingDown:
            symbol = "arrow.down"
        default:
            if !coordinator.signals.deskConnected {
                symbol = "bolt.slash"
            } else if standing {
                symbol = "figure.stand"
                title = Format.duration(state.standStreak)
            } else {
                title = Format.duration(state.sitStreak)
            }
        }

        let key = symbol + "|" + title
        guard key != shown else { return }
        shown = key
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Stehauf")
        button.image = image
        button.imagePosition = .imageLeading
        button.title = image == nil ? "Stehauf \(title)" : title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let coordinator = self.coordinator
        for line in coordinator.statusLines() {
            let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())

        if coordinator.signals.deskConnected {
            if coordinator.state.isMoving {
                menu.addItem(ActionItem("Stopp") { coordinator.stopDesk() })
            } else if coordinator.assessment.posture == .standing {
                menu.addItem(ActionItem("Jetzt runterfahren") { coordinator.perform(.lower) })
            } else {
                menu.addItem(ActionItem("Jetzt hochfahren") { coordinator.perform(.raise) })
            }
        }
        if coordinator.isDisabledToday || coordinator.isSnoozed {
            menu.addItem(ActionItem("Wieder aktivieren") { coordinator.perform(.resume) })
        } else {
            let minutes = Int(coordinator.config.snoozeMinutes)
            menu.addItem(ActionItem("\(minutes) min Pause") { coordinator.perform(.snooze) })
            menu.addItem(ActionItem("Heute nicht mehr") { coordinator.perform(.notToday) })
        }
        menu.addItem(.separator())

        let feedback = NSMenuItem(title: "Erkennung war falsch", action: nil, keyEquivalent: "")
        feedback.submenu = FeedbackMenu.make(coordinator: coordinator)
        menu.addItem(feedback)
        menu.addItem(ActionItem("Status und Einstellungen …") { coordinator.showWindow() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Stehauf beenden") { NSApp.terminate(nil) })
    }
}

/// Einträge, mit denen der Nutzer Fehler der Erkennung im Protokoll markiert.
@MainActor
enum FeedbackMenu {
    struct Entry {
        let title: String
        let kind: String
    }

    static let entries = [
        Entry(title: "Ich bin gerade im Meeting", kind: "missed-meeting"),
        Entry(title: "Ich bin gerade nicht im Meeting", kind: "false-meeting"),
        Entry(title: "Ich bin gerade am Rechner", kind: "missed-presence"),
        Entry(title: "Ich war gerade nicht am Rechner", kind: "false-presence"),
    ]

    static func make(coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            menu.addItem(ActionItem(entry.title) { coordinator.feedback(entry.kind) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Notiz …") { askForNote(coordinator: coordinator) })
        return menu
    }

    static func askForNote(coordinator: Coordinator) {
        let alert = NSAlert()
        alert.messageText = "Was hat nicht gepasst?"
        alert.informativeText = "Die Notiz landet zusammen mit allen aktuellen Messwerten im Protokoll."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        coordinator.feedback("note", note: field.stringValue)
    }
}

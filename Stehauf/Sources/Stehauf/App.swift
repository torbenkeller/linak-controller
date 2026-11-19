import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: Coordinator?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `pkill Stehauf` sauber beenden: Tisch anhalten, Zustand speichern, protokollieren.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        let coordinator = Coordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    /// Wird ausgelöst, wenn die laufende App erneut geöffnet wird, z. B. über
    /// Spotlight. So erreicht man das Fenster auch bei verstecktem Icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showWindow()
        return true
    }

    @objc func showSettings() {
        coordinator?.showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }
}

/// Unsichtbares Hauptmenü, damit ⌘, ⌘W ⌘Q und Kopieren/Einfügen im
/// Einstellungsfenster funktionieren, obwohl die App keine Menüleiste zeigt.
@MainActor
private func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Einstellungen …", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
    appMenu.addItem(withTitle: "Fenster schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Stehauf beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Bearbeiten")
    editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    main.addItem(editItem)
    return main
}

@main
enum StehaufApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = makeMainMenu()
        // Kein Dock-Icon: Die App lebt in der Menüleiste.
        // Zum Testen mit Bildschirmsteuerung lässt sich die App mit
        // STEHAUF_REGULAR_APP=1 als normale App starten.
        let regular = ProcessInfo.processInfo.environment["STEHAUF_REGULAR_APP"] != nil
        app.setActivationPolicy(regular ? .regular : .accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

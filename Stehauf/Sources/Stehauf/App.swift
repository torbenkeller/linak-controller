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

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }
}

@main
enum StehaufApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
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

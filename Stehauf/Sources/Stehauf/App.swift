import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: Coordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

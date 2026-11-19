import AppKit
import Foundation
import StehaufCore

/// Verbindet Sensoren, Tisch, Regelwerk, Protokoll und Oberfläche.
/// Einmal pro Sekunde werden alle Signale gelesen und das Regelwerk befragt.
@MainActor
final class Coordinator: ObservableObject {
    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            engine.config = config
            try? config.encoded().write(to: Paths.config, options: .atomic)
        }
    }
    @Published private(set) var signals = Signals()
    @Published private(set) var assessment = Assessment()
    @Published private(set) var state = EngineState()
    @Published private(set) var deskStatus: DeskBLE.Status = .searching
    @Published private(set) var deskName: String?
    @Published private(set) var calendarAuthorized = false
    @Published private(set) var now = Date()

    private var engine: Engine
    private var detector = Detector()
    private let desk: DeskBLE
    private let calendar = CalendarSensor()
    private let screen = ScreenSensor()
    private let logger = EventLogger()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private let simulatedDesk: SimulatedDesk?
    private var lastDeskReady = false

    private var microphone = MicrophoneSensor.Reading()
    private var cameraInUse = false
    private var lastSlowPoll = Date.distantPast
    private var lastSample = Date.distantPast
    private var lastSampleKey = ""
    private var lastStateSave = Date.distantPast
    private var wasAnnouncing = false

    private var statusItem: StatusItemController?
    private var panel: CountdownPanelController?
    private var window: StatusWindowController?
    let isFirstLaunch: Bool

    init() {
        isFirstLaunch = !FileManager.default.fileExists(atPath: Paths.config.path)
        let loaded = (try? Data(contentsOf: Paths.config)).map(Config.load(from:)) ?? Config()
        config = loaded
        engine = Engine(config: loaded, state: Coordinator.restoredState())
        desk = DeskBLE(fallbackBaseMM: loaded.fallbackBaseHeightMM)
        let simulate = ProcessInfo.processInfo.environment["STEHAUF_FAKE_DESK"] != nil
        simulatedDesk = simulate ? SimulatedDesk(height: loaded.sitHeightMM) : nil
        desk.preferredIdentifier = loaded.deskIdentifier.flatMap(UUID.init(uuidString:))
    }

    /// Übernimmt Tageswerte und Sitz-Uhr vom letzten Lauf, sofern er frisch ist.
    private static func restoredState() -> EngineState {
        guard let data = try? Data(contentsOf: Paths.state),
              var saved = try? JSONDecoder().decode(EngineState.self, from: data)
        else { return EngineState() }
        let fresh = saved.lastTick.map { Date().timeIntervalSince($0) < 600 } ?? false
        if !fresh {
            saved.sitStreak = 0
            saved.standStreak = 0
        }
        saved.phase = .inactive
        saved.lastPosture = nil
        saved.announceStarted = nil
        saved.deadline = nil
        saved.waitingForPresence = false
        saved.moveStarted = nil
        saved.awaySince = nil
        saved.returnBoostUntil = nil
        saved.lastTick = nil
        return saved
    }

    func start() {
        if isFirstLaunch { try? config.encoded().write(to: Paths.config, options: .atomic) }
        statusItem = StatusItemController(coordinator: self)
        panel = CountdownPanelController(coordinator: self)
        window = StatusWindowController(coordinator: self)

        desk.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.deskChanged() }
        }
        desk.onLog = { [weak self] message in
            MainActor.assumeIsolated { self?.log(kind: "desk", message: message) }
        }
        if simulatedDesk == nil { desk.start() }

        calendarAuthorized = calendar.authorized
        if config.useCalendar && !calendarAuthorized { requestCalendarAccess() }

        log(kind: "app", message: simulatedDesk == nil ? "Start" : "Start mit simuliertem Tisch")
        tick()
        if isFirstLaunch { showWindow() }
    }

    func shutdown() {
        desk.stop()
        saveState()
        log(kind: "app", message: "Ende")
        logger.close()
    }

    // MARK: Takt

    /// Wie oft die App aufwacht. Sie soll im Hintergrund kaum Strom brauchen:
    /// - Ankündigung, Fahrt oder offenes Statusfenster: jede Sekunde
    /// - am Rechner, Tisch verbunden: alle 5 Sekunden
    /// - nicht am Rechner: alle 10 Sekunden (nur um die Rückkehr zu bemerken)
    /// - Tisch nicht erreichbar: einmal pro Minute, ohne Sensoren abzufragen
    private var tickInterval: Double {
        if engine.state.isAnnouncing || engine.state.isMoving || (window?.isVisible ?? false) { return 1 }
        if !signals.deskConnected { return 60 }
        return assessment.present ? 5 : 10
    }

    private func scheduleNextTick() {
        timer?.invalidate()
        let interval = tickInterval
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Spielraum, damit macOS das Aufwachen mit anderen Timern bündeln kann.
        next.tolerance = interval * 0.2
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    /// Hält macOS nur dann davon ab, die App zu drosseln (App Nap), wenn es
    /// auf pünktliche Timer ankommt: während Countdown und Fahrt.
    private func updateActivity() {
        let needed = engine.state.isAnnouncing || engine.state.isMoving
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Schreibtisch fährt"
            )
        } else if !needed, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    private func tick() {
        let now = Date()
        var signals = Signals()
        if let simulated = simulatedDesk {
            signals.deskConnected = true
            signals.deskHeightMM = simulated.height(at: now)
            signals.deskMoving = simulated.isMoving(at: now)
        } else {
            signals.deskConnected = desk.status == .ready
            signals.deskHeightMM = desk.heightMM.map { $0.rounded() }
            signals.deskMoving = desk.isMoving
        }

        // Ohne Tisch kann die App nichts tun. Dann fragt sie auch Mikrofon,
        // Kamera und Kalender nicht ab, außer das Statusfenster ist offen.
        let sensing = signals.deskConnected || (window?.isVisible ?? false)
        if sensing, now.timeIntervalSince(lastSlowPoll) >= 2 {
            lastSlowPoll = now
            microphone = MicrophoneSensor.read()
            cameraInUse = CameraSensor.inUse()
        } else if !sensing {
            microphone = MicrophoneSensor.Reading()
            cameraInUse = false
        }

        signals.idleSeconds = InputIdle.seconds(.hidSystemState)
        signals.idleSessionSeconds = InputIdle.seconds(.combinedSessionState)
        signals.screenLocked = screen.locked
        signals.micApps = microphone.apps
        signals.micInUse = microphone.inUse
        signals.cameraInUse = cameraInUse
        if config.useCalendar && sensing {
            let reading = calendar.read(now: now, requireAttendees: config.calendarRequiresAttendees)
            signals.calendarBusy = reading.busy
            signals.minutesToNextMeeting = reading.minutesToNext
        }

        let assessment = detector.assess(signals, now: now, config: config)
        let actions = engine.step(signals: signals, assessment: assessment, now: now)

        self.signals = signals
        self.assessment = assessment
        self.now = now
        execute(actions)
        publish()
        sampleIfNeeded(now)
        if now.timeIntervalSince(lastStateSave) > 60 { saveState() }
        scheduleNextTick()
    }

    private func publish() {
        state = engine.state
        deskStatus = desk.status
        deskName = desk.name
        updateActivity()
        if state.isAnnouncing && !wasAnnouncing && config.soundEnabled {
            NSSound(named: "Glass")?.play()
        }
        wasAnnouncing = state.isAnnouncing
        statusItem?.update()
        panel?.update()
    }

    private func execute(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .nudge(let direction):
                if simulatedDesk == nil { nudgeDesk(direction) }
            case .move(_, let target):
                if let simulated = simulatedDesk {
                    simulated.move(to: target, at: Date())
                } else {
                    desk.move(toMM: target)
                }
            case .stop:
                simulatedDesk?.stop(at: Date())
                desk.stop()
            case .note(let message):
                state = engine.state
                log(kind: "decision", message: message)
            }
        }
    }

    private func deskChanged() {
        deskStatus = desk.status
        deskName = desk.name
        if desk.status == .ready, let id = desk.identifier?.uuidString, config.deskIdentifier != id {
            config.deskIdentifier = id
            desk.preferredIdentifier = desk.identifier
        }
        // Verbindung da oder weg: sofort neu bewerten statt auf den nächsten
        // langsamen Takt zu warten. Asynchron, weil diese Meldung auch mitten
        // in einem Takt kommen kann.
        let ready = desk.status == .ready
        if ready != lastDeskReady {
            lastDeskReady = ready
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    // MARK: Aktionen aus der Oberfläche

    func perform(_ action: UserAction) {
        let actions = engine.handle(action, signals: signals, assessment: assessment, now: Date())
        execute(actions)
        publish()
        scheduleNextTick()
    }

    /// Der Nutzer markiert, dass die Erkennung gerade falsch liegt.
    func feedback(_ kind: String, note: String? = nil) {
        let message = note.map { "\(kind): \($0)" } ?? kind
        log(kind: "feedback", message: message)
    }

    func useCurrentHeight(for direction: Direction) {
        guard let height = signals.deskHeightMM else { return }
        var updated = config
        if direction == .up {
            updated.standHeightMM = height.rounded()
            updated.standHeightConfirmed = true
        } else {
            updated.sitHeightMM = height.rounded()
            updated.sitHeightConfirmed = true
        }
        config = updated
    }

    /// Stupser zum Ausprobieren aus dem Statusfenster.
    func testNudge() {
        guard simulatedDesk == nil, config.heightsConfirmed, !engine.state.isMoving else { return }
        log(kind: "decision", message: "Nutzer: Stupser testen")
        nudgeDesk(.up)
    }

    private func nudgeDesk(_ direction: Direction) {
        if config.nudgeUsesButtons {
            desk.nudgeWithButtons(direction, mm: config.nudgeMM, pause: config.nudgeButtonPauseSeconds)
        } else {
            desk.nudge(direction, mm: config.nudgeMM, pause: config.nudgePauseSeconds)
        }
    }

    /// Not-Halt aus der Oberfläche. Das Regelwerk bemerkt den Abbruch selbst.
    func stopDesk() {
        simulatedDesk?.stop(at: Date())
        desk.stop()
        log(kind: "decision", message: "Nutzer: Stopp")
    }

    func forgetDesk() {
        config.deskIdentifier = nil
        desk.preferredIdentifier = nil
        desk.restart()
    }

    func requestCalendarAccess() {
        calendar.requestAccess { [weak self] granted in
            MainActor.assumeIsolated { self?.calendarAuthorized = granted }
        }
    }

    func showWindow() {
        window?.show()
        // Solange das Fenster offen ist, läuft der Takt im Sekundenabstand.
        tick()
    }

    func openLogFolder() {
        NSWorkspace.shared.open(Paths.logs)
    }

    func openConfigFile() {
        NSWorkspace.shared.open(Paths.config)
    }

    func reloadConfig() {
        guard let data = try? Data(contentsOf: Paths.config) else { return }
        config = Config.load(from: data)
    }

    // MARK: Protokoll

    private func log(kind: String, message: String) {
        var record = logger.record(kind: kind, message: message)
        record.attach(signals: signals, assessment: assessment, state: engine.state)
        logger.write(record)
    }

    /// Schreibt einen Messpunkt, wenn sich etwas Wesentliches geändert hat
    /// oder das Intervall abgelaufen ist.
    private func sampleIfNeeded(_ now: Date) {
        let key = [
            String(signals.deskConnected), String(assessment.present), assessment.posture.rawValue,
            assessment.meetingReasons.joined(separator: ","), String(assessment.meetingSoon),
            signals.micApps.joined(separator: ","), String(signals.micInUse), String(signals.cameraInUse),
            String(signals.screenLocked), engine.state.phase.rawValue, engine.state.blocked ?? "",
        ].joined(separator: "|")
        // Ohne Tisch oder ohne Nutzer reicht ein Messpunkt pro Änderung.
        let watching = signals.deskConnected && assessment.present
        let intervalElapsed = watching && now.timeIntervalSince(lastSample) >= config.sampleIntervalSeconds
        guard key != lastSampleKey || intervalElapsed else { return }
        lastSampleKey = key
        lastSample = now
        var record = logger.record(kind: "sample", at: now)
        record.attach(signals: signals, assessment: assessment, state: engine.state)
        logger.write(record, at: now)
    }

    private func saveState() {
        lastStateSave = Date()
        if let data = try? JSONEncoder().encode(engine.state) {
            try? data.write(to: Paths.state, options: .atomic)
        }
    }
}

/// Simulierter Tisch zum Ausprobieren ohne Hardware. Aktiv, wenn die App mit
/// der Umgebungsvariable `STEHAUF_FAKE_DESK=1` gestartet wird. Er fährt mit
/// 40 mm pro Sekunde, ähnlich wie ein echter Tisch.
final class SimulatedDesk {
    private var origin: Double
    private var target: Double
    private var started = Date.distantPast
    private let speed = 40.0

    init(height: Double) {
        origin = height
        target = height
    }

    func height(at now: Date) -> Double {
        let travelled = max(0, now.timeIntervalSince(started)) * speed
        let distance = abs(target - origin)
        guard travelled < distance else { return target }
        return (origin + (target > origin ? travelled : -travelled)).rounded()
    }

    func isMoving(at now: Date) -> Bool {
        height(at: now) != target
    }

    func move(to newTarget: Double, at now: Date) {
        origin = height(at: now)
        target = newTarget
        started = now
    }

    func stop(at now: Date) {
        let current = height(at: now)
        origin = current
        target = current
    }
}

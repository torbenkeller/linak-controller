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
        desk.start()

        calendarAuthorized = calendar.authorized
        if config.useCalendar && !calendarAuthorized { requestCalendarAccess() }

        // Ohne das bremst macOS die Timer einer App ohne sichtbares Fenster
        // (App Nap), und die Fahrbefehle kämen zu spät.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Steuert den Schreibtisch"
        )

        log(kind: "app", message: "Start")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastSlowPoll) >= 2 {
            lastSlowPoll = now
            microphone = MicrophoneSensor.read()
            cameraInUse = CameraSensor.inUse()
        }

        var signals = Signals()
        signals.deskConnected = desk.status == .ready
        signals.deskHeightMM = desk.heightMM.map { $0.rounded() }
        signals.deskMoving = desk.isMoving
        signals.idleSeconds = InputIdle.seconds(.hidSystemState)
        signals.idleSessionSeconds = InputIdle.seconds(.combinedSessionState)
        signals.screenLocked = screen.locked
        signals.micApps = microphone.apps
        signals.micInUse = microphone.inUse
        signals.cameraInUse = cameraInUse
        if config.useCalendar {
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
    }

    private func publish() {
        state = engine.state
        deskStatus = desk.status
        deskName = desk.name
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
                desk.nudge(direction, mm: config.nudgeMM)
            case .move(_, let target):
                desk.move(toMM: target)
            case .stop:
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
    }

    // MARK: Aktionen aus der Oberfläche

    func perform(_ action: UserAction) {
        let actions = engine.handle(action, signals: signals, assessment: assessment, now: Date())
        execute(actions)
        publish()
    }

    /// Der Nutzer markiert, dass die Erkennung gerade falsch liegt.
    func feedback(_ kind: String, note: String? = nil) {
        let message = note.map { "\(kind): \($0)" } ?? kind
        log(kind: "feedback", message: message)
    }

    func useCurrentHeight(for direction: Direction) {
        guard let height = desk.heightMM else { return }
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

    /// Not-Halt aus der Oberfläche. Das Regelwerk bemerkt den Abbruch selbst.
    func stopDesk() {
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

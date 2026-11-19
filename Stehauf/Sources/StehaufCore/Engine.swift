import Foundation

public enum Direction: String, Codable {
    case up, down
}

public enum Phase: String, Codable {
    /// Tisch nicht erreichbar (z. B. im Büro in Berlin): Die App tut nichts.
    case inactive
    case away
    case sitting
    case standing
    case announcingUp
    case announcingDown
    case movingUp
    case movingDown
}

/// Was die Umgebung nach einem Schritt des Regelwerks ausführen soll.
public enum Action: Equatable {
    case nudge(Direction)
    case move(Direction, targetMM: Double)
    case stop
    /// Entscheidung fürs Protokoll.
    case note(String)
}

public enum UserAction: Equatable {
    /// „Später“ bzw. „Weiter stehen“.
    case snooze
    /// „Bin im Meeting“.
    case inMeeting
    case notToday
    /// Pausen und „Heute nicht“ aufheben.
    case resume
    /// Während einer Ankündigung sofort fahren.
    case goNow
    case raise
    case lower
}

public struct EngineState: Codable, Equatable {
    public var phase: Phase = .inactive
    /// Sekunden, die man anwesend gesessen hat, seit man zuletzt stand.
    public var sitStreak: Double = 0
    /// Sekunden der laufenden Stehphase.
    public var standStreak: Double = 0
    public var lastPosture: Posture? = nil
    public var announceStarted: Date? = nil
    public var deadline: Date? = nil
    /// Countdown abgelaufen, aber keine Eingabe gesehen: wartet auf den Nutzer.
    public var waitingForPresence: Bool = false
    public var moveStarted: Date? = nil
    public var snoozeUntil: Date? = nil
    public var disabledDay: String? = nil
    public var awaySince: Date? = nil
    public var returnBoostUntil: Date? = nil
    public var lastTick: Date? = nil
    /// Warum gerade nicht angekündigt wird, obwohl es fällig wäre.
    public var blocked: String? = nil
    public var day: String = ""
    public var sitSecondsToday: Double = 0
    public var standSecondsToday: Double = 0
    public var raisesToday: Int = 0

    public init() {}

    public var isAnnouncing: Bool { phase == .announcingUp || phase == .announcingDown }
    public var isMoving: Bool { phase == .movingUp || phase == .movingDown }
}

/// Das Regelwerk: entscheidet aus Signalen und Zeit, wann angekündigt und
/// gefahren wird. Enthält keinen Zugriff auf Bluetooth, Uhr oder Oberfläche
/// und ist deshalb vollständig testbar.
public struct Engine {
    public var config: Config
    public var state: EngineState
    public var calendar: Calendar

    /// Größter Abstand zwischen zwei Schritten, der noch als gesessene oder
    /// gestandene Zeit zählt. Längere Lücken sind Ruhezustand oder Neustart.
    static let maxTickGap: Double = 10
    /// So lange nach Fahrtbeginn wird nicht geprüft, ob der Tisch steht.
    static let moveSettleSeconds: Double = 4
    static let returnBoostSeconds: Double = 120

    public init(config: Config, state: EngineState = EngineState(), calendar: Calendar = .current) {
        self.config = config
        self.state = state
        self.calendar = calendar
    }

    // MARK: Schritt

    public mutating func step(signals: Signals, assessment: Assessment, now: Date) -> [Action] {
        var actions: [Action] = []
        let dt = elapsed(until: now)
        state.lastTick = now
        rollover(now)

        guard signals.deskConnected, assessment.posture != .unknown else {
            if state.phase != .inactive { actions.append(.note("Tisch nicht erreichbar, App ruht")) }
            state.phase = .inactive
            state.lastPosture = nil
            state.moveStarted = nil
            state.blocked = "desk-unavailable"
            clearAnnouncement()
            return actions
        }

        if state.isMoving {
            let target: Posture = state.phase == .movingUp ? .standing : .sitting
            let age = now.timeIntervalSince(state.moveStarted ?? now)
            if !signals.deskMoving && age >= Engine.moveSettleSeconds {
                if assessment.posture == target {
                    actions.append(.note("Fahrt beendet"))
                } else {
                    actions.append(.note("Fahrt abgebrochen: Tisch hat vor dem Ziel angehalten"))
                    state.snoozeUntil = now.addingTimeInterval(config.snoozeMinutes * 60)
                }
            } else if age > config.moveTimeoutSeconds {
                actions.append(.stop)
                actions.append(.note("Fahrt abgebrochen: Zeitlimit"))
                state.snoozeUntil = now.addingTimeInterval(config.snoozeMinutes * 60)
            } else {
                state.blocked = nil
                return actions
            }
            state.moveStarted = nil
            state.phase = basePhase(assessment)
        }

        if let last = state.lastPosture, last != assessment.posture {
            if assessment.posture == .standing {
                state.standStreak = 0
                actions.append(.note("Tisch ist oben"))
            } else {
                if state.standStreak >= config.minStandResetSeconds { state.sitStreak = 0 }
                state.standStreak = 0
                actions.append(.note("Tisch ist unten"))
            }
            if state.isAnnouncing {
                clearAnnouncement()
                state.phase = basePhase(assessment)
            }
        }
        state.lastPosture = assessment.posture

        if assessment.present {
            if let since = state.awaySince {
                if now.timeIntervalSince(since) >= config.returnMinAwaySeconds {
                    state.returnBoostUntil = now.addingTimeInterval(Engine.returnBoostSeconds)
                }
                state.awaySince = nil
            }
            if assessment.posture == .standing {
                state.standStreak += dt
                state.standSecondsToday += dt
            } else {
                state.sitStreak += dt
                state.sitSecondsToday += dt
            }
        } else if state.awaySince == nil {
            state.awaySince = now
        }

        if state.isAnnouncing {
            let direction: Direction = state.phase == .announcingUp ? .up : .down
            if let reason = blockReason(direction, signals: signals, assessment: assessment, now: now, announcing: true) {
                actions.append(.note("Ankündigung abgebrochen: \(reason)"))
                clearAnnouncement()
                state.phase = basePhase(assessment)
                state.blocked = reason
                return actions
            }
            state.blocked = nil
            if state.waitingForPresence {
                if signals.idleSeconds <= 5 {
                    state.waitingForPresence = false
                    state.deadline = now.addingTimeInterval(config.resumeCountdownSeconds)
                    actions.append(.note("Eingabe gesehen, kurzer Countdown"))
                }
            } else if let deadline = state.deadline, now >= deadline {
                let sinceStart = now.timeIntervalSince(state.announceStarted ?? now)
                let sawInput = signals.idleSeconds <= sinceStart
                if sawInput || !config.requireInputDuringCountdown {
                    actions.append(contentsOf: startMove(direction, now: now))
                } else {
                    state.waitingForPresence = true
                    state.deadline = nil
                    actions.append(.note("Keine Eingabe während des Countdowns, warte auf Nutzer"))
                }
            }
            return actions
        }

        state.phase = basePhase(assessment)
        guard assessment.present else {
            state.blocked = "away"
            return actions
        }

        let direction: Direction = assessment.posture == .sitting ? .up : .down
        guard isDue(direction, now: now) else {
            state.blocked = nil
            return actions
        }
        if let reason = blockReason(direction, signals: signals, assessment: assessment, now: now, announcing: false) {
            state.blocked = reason
            return actions
        }

        state.blocked = nil
        state.phase = direction == .up ? .announcingUp : .announcingDown
        state.announceStarted = now
        state.deadline = now.addingTimeInterval(config.countdownSeconds)
        state.waitingForPresence = false
        state.returnBoostUntil = nil
        if config.nudgeEnabled { actions.append(.nudge(direction)) }
        actions.append(.note("Ankündigung \(direction.rawValue)"))
        return actions
    }

    // MARK: Nutzeraktionen

    public mutating func handle(_ action: UserAction, signals: Signals, assessment: Assessment, now: Date) -> [Action] {
        switch action {
        case .snooze:
            state.snoozeUntil = now.addingTimeInterval(config.snoozeMinutes * 60)
            cancelAnnouncement(assessment)
            return [.note("Nutzer: später")]
        case .inMeeting:
            state.snoozeUntil = now.addingTimeInterval(config.meetingSnoozeMinutes * 60)
            cancelAnnouncement(assessment)
            return [.note("Nutzer: bin im Meeting")]
        case .notToday:
            state.disabledDay = dayKey(now)
            cancelAnnouncement(assessment)
            return [.note("Nutzer: heute nicht")]
        case .resume:
            state.disabledDay = nil
            state.snoozeUntil = nil
            return [.note("Nutzer: wieder aktiv")]
        case .goNow:
            guard state.isAnnouncing else { return [] }
            return startMove(state.phase == .announcingUp ? .up : .down, now: now)
        case .raise, .lower:
            guard signals.deskConnected, !state.isMoving, config.heightsConfirmed else { return [] }
            return startMove(action == .raise ? .up : .down, now: now)
        }
    }

    // MARK: Hilfen

    private func basePhase(_ assessment: Assessment) -> Phase {
        guard assessment.present else { return .away }
        return assessment.posture == .standing ? .standing : .sitting
    }

    private func isDue(_ direction: Direction, now: Date) -> Bool {
        switch direction {
        case .up:
            let needed = config.sitMinutes * 60
            if state.sitStreak >= needed { return true }
            let boosted = state.returnBoostUntil.map { now < $0 } ?? false
            return boosted && state.sitStreak >= needed * config.returnTriggerFraction
        case .down:
            return config.autoDown && state.standStreak >= config.standMinutes * 60
        }
    }

    private func blockReason(
        _ direction: Direction, signals: Signals, assessment: Assessment, now: Date, announcing: Bool
    ) -> String? {
        if !config.heightsConfirmed { return "setup" }
        if state.disabledDay == dayKey(now) { return "disabled-today" }
        if let until = state.snoozeUntil, now < until { return "snoozed" }
        if !inActiveHours(now) { return "outside-hours" }
        if !assessment.present { return "away" }
        if assessment.inMeeting { return "meeting" }
        if direction == .up && assessment.meetingSoon { return "meeting-soon" }
        if assessment.meetingRecentlyEnded { return "meeting-just-ended" }
        if !announcing {
            if signals.deskMoving { return "desk-moving" }
            if signals.idleSeconds > config.activeIdleSeconds { return "idle" }
        }
        return nil
    }

    private mutating func startMove(_ direction: Direction, now: Date) -> [Action] {
        clearAnnouncement()
        state.phase = direction == .up ? .movingUp : .movingDown
        state.moveStarted = now
        state.blocked = nil
        if direction == .up { state.raisesToday += 1 }
        let target = direction == .up ? config.standHeightMM : config.sitHeightMM
        return [.move(direction, targetMM: target), .note("Fahre \(direction.rawValue) auf \(Int(target)) mm")]
    }

    private mutating func cancelAnnouncement(_ assessment: Assessment) {
        guard state.isAnnouncing else { return }
        clearAnnouncement()
        state.phase = basePhase(assessment)
    }

    private mutating func clearAnnouncement() {
        state.announceStarted = nil
        state.deadline = nil
        state.waitingForPresence = false
    }

    private func elapsed(until now: Date) -> Double {
        guard let last = state.lastTick else { return 0 }
        let dt = now.timeIntervalSince(last)
        return (dt < 0 || dt > Engine.maxTickGap) ? 0 : dt
    }

    private mutating func rollover(_ now: Date) {
        let key = dayKey(now)
        guard key != state.day else { return }
        state.day = key
        state.sitSecondsToday = 0
        state.standSecondsToday = 0
        state.raisesToday = 0
    }

    public func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func inActiveHours(_ now: Date) -> Bool {
        guard let start = config.activeHoursStart, let end = config.activeHoursEnd else { return true }
        let hour = calendar.component(.hour, from: now)
        return hour >= start && hour < end
    }
}

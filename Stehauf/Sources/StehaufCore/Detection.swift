import Foundation

public enum Posture: String, Codable {
    case sitting, standing, unknown
}

/// Rohsignale eines Zeitpunkts, so wie die Sensoren sie liefern.
public struct Signals: Codable, Equatable {
    public var deskConnected: Bool = false
    public var deskHeightMM: Double? = nil
    public var deskMoving: Bool = false
    /// Sekunden seit der letzten echten Tastatur- oder Mauseingabe.
    public var idleSeconds: Double = 0
    /// Dasselbe inklusive simulierter Eingaben; nur zum Vergleich im Log.
    public var idleSessionSeconds: Double? = nil
    public var screenLocked: Bool = false
    /// Bundle-IDs der Apps, die gerade vom Mikrofon aufnehmen.
    public var micApps: [String] = []
    public var micInUse: Bool = false
    public var cameraInUse: Bool = false
    public var calendarBusy: Bool = false
    public var minutesToNextMeeting: Double? = nil

    public init() {}
}

/// Was die App aus den Rohsignalen ableitet.
public struct Assessment: Codable, Equatable {
    public var present: Bool = false
    public var posture: Posture = .unknown
    public var inMeeting: Bool = false
    /// Gründe für die Meeting-Erkennung, z. B. `camera`, `app:com.microsoft.teams2`.
    public var meetingReasons: [String] = []
    public var meetingSoon: Bool = false
    public var meetingRecentlyEnded: Bool = false

    public init() {}
}

public enum MicAppKind: Equatable {
    case meeting, ignored, unknown
}

/// Leitet Anwesenheit, Haltung und Meeting-Status ab. Merkt sich dafür, seit
/// wann das Mikrofon läuft und wann zuletzt ein Meeting erkannt wurde.
public struct Detector {
    public var micSince: Date? = nil
    public var lastMeetingSeen: Date? = nil

    public init() {}

    public static func classify(_ app: String, config: Config) -> MicAppKind {
        let name = app.lowercased()
        if config.ignoredMicAppPatterns.contains(where: { name.contains($0.lowercased()) }) { return .ignored }
        if config.meetingAppPatterns.contains(where: { name.contains($0.lowercased()) }) { return .meeting }
        return .unknown
    }

    public mutating func assess(_ signals: Signals, now: Date, config: Config) -> Assessment {
        var result = Assessment()

        if let height = signals.deskHeightMM, signals.deskConnected {
            result.posture = height >= config.standThresholdMM ? .standing : .sitting
        }

        if signals.micInUse {
            if micSince == nil { micSince = now }
        } else {
            micSince = nil
        }

        var reasons: [String] = []
        if signals.cameraInUse { reasons.append("camera") }

        var onlyIgnored = !signals.micApps.isEmpty
        for app in signals.micApps {
            switch Detector.classify(app, config: config) {
            case .meeting:
                reasons.append("app:\(app)")
                onlyIgnored = false
            case .unknown:
                onlyIgnored = false
            case .ignored:
                break
            }
        }
        if signals.micInUse, !onlyIgnored, let since = micSince,
           now.timeIntervalSince(since) >= config.micSustainedSeconds {
            reasons.append("mic-sustained")
        }
        let hardEvidence = !reasons.isEmpty
        if signals.calendarBusy { reasons.append("calendar") }

        result.meetingReasons = reasons
        result.inMeeting = !reasons.isEmpty
        if result.inMeeting {
            lastMeetingSeen = now
        } else if let last = lastMeetingSeen, now.timeIntervalSince(last) < config.meetingGraceSeconds {
            result.meetingRecentlyEnded = true
        }

        if let minutes = signals.minutesToNextMeeting, minutes <= config.meetingLeadMinutes {
            result.meetingSoon = true
        }

        // In einem Gespräch fasst man die Tastatur oft minutenlang nicht an.
        // Kamera oder Mikrofon zählen deshalb als Anwesenheit, ein reiner
        // Kalendereintrag nicht.
        let recentInput = signals.idleSeconds < config.presenceTimeoutSeconds
        result.present = !signals.screenLocked && (recentInput || hardEvidence)
        return result
    }
}

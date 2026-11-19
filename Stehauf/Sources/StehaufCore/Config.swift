import Foundation

public enum MenuBarMode: String, Codable, CaseIterable {
    /// Icon nur während Ankündigung, Fahrt und Stehphase.
    case whenRelevant
    case always
}

/// Alle Einstellungen. Wird als `config.json` gespeichert; fehlende Schlüssel
/// werden beim Laden mit den Standardwerten aufgefüllt.
public struct Config: Codable, Equatable {
    // Rhythmus
    public var sitMinutes: Double = 45
    public var standMinutes: Double = 20
    /// Nach der Stehphase mit derselben Ankündigung wieder herunterfahren.
    public var autoDown: Bool = true

    // Tisch
    public var sitHeightMM: Double = 720
    public var standHeightMM: Double = 1100
    /// Erst wenn beide Höhen am echten Tisch übernommen wurden, fährt die App.
    public var sitHeightConfirmed: Bool = false
    public var standHeightConfirmed: Bool = false
    /// Wird nur benutzt, wenn der Tisch seine unterste Höhe nicht meldet.
    public var fallbackBaseHeightMM: Double = 620
    public var deskIdentifier: String? = nil
    public var moveTimeoutSeconds: Double = 60

    // Ankündigung
    public var countdownSeconds: Double = 60
    /// Kurzer Countdown, nachdem auf eine Eingabe gewartet wurde.
    public var resumeCountdownSeconds: Double = 10
    public var nudgeEnabled: Bool = true
    public var nudgeMM: Double = 10
    public var soundEnabled: Bool = true
    /// Der Tisch fährt nur, wenn während des Countdowns eine Eingabe kam.
    public var requireInputDuringCountdown: Bool = true
    public var snoozeMinutes: Double = 15
    public var meetingSnoozeMinutes: Double = 30

    // Anwesenheit
    /// Ohne Eingabe gilt man nach dieser Zeit als abwesend.
    public var presenceTimeoutSeconds: Double = 300
    /// Eine Ankündigung startet nur, wenn die letzte Eingabe so frisch ist.
    public var activeIdleSeconds: Double = 30
    /// Ab dieser Abwesenheit zählt die Rückkehr als guter Moment zum Hochfahren.
    public var returnMinAwaySeconds: Double = 180
    /// Anteil der Sitzzeit, der bei einer Rückkehr schon reicht.
    public var returnTriggerFraction: Double = 0.6
    /// So lange muss man gestanden haben, damit die Sitz-Uhr auf null geht.
    public var minStandResetSeconds: Double = 300
    public var activeHoursStart: Int? = nil
    public var activeHoursEnd: Int? = nil

    // Meetings
    /// Teilstrings von Bundle-IDs. Nutzt eine solche App das Mikrofon, gilt
    /// das sofort als Meeting.
    public var meetingAppPatterns: [String] = [
        "teams", "chrome", "safari", "webkit", "firefox", "edgemac", "thebrowser", "brave",
        "slack", "zoom", "granola", "facetime", "webex", "discord", "whatsapp", "signal", "telegram",
    ]
    /// Teilstrings von Bundle-IDs, deren Mikrofonnutzung ignoriert wird
    /// (Diktier-Tools und Systemdienste).
    public var ignoredMicAppPatterns: [String] = [
        "whisper", "wispr", "dictation", "corespeech", "siri", "speechrecognition", "voicecontrol", "stehauf",
    ]
    /// Nutzt eine unbekannte App das Mikrofon so lange am Stück, gilt das als Meeting.
    public var micSustainedSeconds: Double = 120
    /// Wartezeit nach Meeting-Ende, bevor wieder angekündigt wird.
    public var meetingGraceSeconds: Double = 60
    /// So kurz vor einem Kalendertermin wird nicht mehr hochgefahren.
    public var meetingLeadMinutes: Double = 5
    public var useCalendar: Bool = true
    public var calendarRequiresAttendees: Bool = true

    // Oberfläche und Protokoll
    public var menuBarMode: MenuBarMode = .whenRelevant
    public var sampleIntervalSeconds: Double = 15

    public init() {}

    public var heightsConfirmed: Bool {
        sitHeightConfirmed && standHeightConfirmed && standHeightMM - sitHeightMM >= 100
    }

    /// Ab dieser Höhe gilt der Tisch als „oben“.
    public var standThresholdMM: Double { (sitHeightMM + standHeightMM) / 2 }

    /// Lädt eine Konfiguration und füllt fehlende Schlüssel mit Standardwerten.
    public static func load(from data: Data) -> Config {
        guard
            let defaultsData = try? JSONEncoder().encode(Config()),
            let defaults = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any],
            let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Config() }
        let merged = defaults.merging(user) { _, new in new }
        guard
            let mergedData = try? JSONSerialization.data(withJSONObject: merged),
            let config = try? JSONDecoder().decode(Config.self, from: mergedData)
        else { return Config() }
        return config
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

import Foundation
import StehaufCore

/// Texte für Menü, Ankündigung und Statusfenster.
enum Format {
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func countdown(to deadline: Date?, now: Date) -> String {
        guard let deadline else { return "" }
        let remaining = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    static func height(_ mm: Double?) -> String {
        guard let mm else { return "unbekannt" }
        return String(format: "%.1f cm", mm / 10).replacingOccurrences(of: ".", with: ",")
    }

    static func desk(_ status: DeskBLE.Status) -> String {
        switch status {
        case .bluetoothOff: return "Bluetooth ist aus"
        case .unauthorized: return "Bluetooth-Zugriff fehlt"
        case .searching: return "wird gesucht"
        case .searchPaused: return "nicht gefunden, Suche pausiert"
        case .connecting: return "nicht in Reichweite"
        case .initialising: return "verbindet"
        case .ready: return "verbunden"
        }
    }

    static func blocked(_ reason: String?) -> String? {
        switch reason {
        case "setup": return "Sitz- und Stehhöhe sind noch nicht festgelegt"
        case "meeting": return "Meeting erkannt"
        case "meeting-soon": return "Termin beginnt gleich"
        case "meeting-just-ended": return "Meeting gerade beendet"
        case "snoozed": return "Pause"
        case "disabled-today": return "für heute ausgeschaltet"
        case "outside-hours": return "außerhalb der aktiven Stunden"
        case "idle": return "wartet auf eine Eingabe"
        case "desk-moving": return "Tisch bewegt sich"
        default: return nil
        }
    }

    static func meetingReason(_ reason: String) -> String {
        switch reason {
        case "camera": return "Kamera läuft"
        case "calendar": return "Kalendertermin"
        case "mic-sustained": return "Mikrofon läuft lange"
        default: return reason.hasPrefix("app:") ? String(reason.dropFirst(4)) : reason
        }
    }
}

extension Coordinator {
    /// Was die App gerade erkennt, in ganzen Sätzen. Dient auch dazu, Fehler
    /// der Erkennung zu bemerken und zu markieren.
    func statusLines() -> [String] {
        var lines: [String] = []
        if signals.deskConnected {
            lines.append("Tisch: verbunden, \(Format.height(signals.deskHeightMM))")
        } else {
            lines.append("Tisch: \(Format.desk(deskStatus))")
        }

        if assessment.present {
            lines.append("Am Rechner: ja")
        } else if signals.screenLocked {
            lines.append("Am Rechner: nein (Bildschirm gesperrt)")
        } else {
            lines.append("Am Rechner: nein (letzte Eingabe vor \(Format.duration(signals.idleSeconds)))")
        }

        if assessment.inMeeting {
            let reasons = assessment.meetingReasons.map(Format.meetingReason).joined(separator: ", ")
            lines.append("Meeting: ja (\(reasons))")
        } else {
            lines.append("Meeting: nein")
        }
        if !signals.micApps.isEmpty {
            lines.append("Mikrofon: \(signals.micApps.joined(separator: ", "))")
        }

        guard signals.deskConnected else { return lines }
        switch state.phase {
        case .announcingUp: lines.append("Ankündigung: fährt gleich hoch")
        case .announcingDown: lines.append("Ankündigung: fährt gleich runter")
        case .movingUp: lines.append("Fährt hoch")
        case .movingDown: lines.append("Fährt runter")
        default:
            if assessment.posture == .standing {
                lines.append("Steht seit \(Format.duration(state.standStreak))")
            } else {
                lines.append("Sitzt seit \(Format.duration(state.sitStreak)) von \(Int(config.sitMinutes)) min")
            }
        }
        if let blocked = Format.blocked(state.blocked) {
            lines.append("Wartet: \(blocked)")
        }
        lines.append("Heute gestanden: \(Format.duration(state.standSecondsToday)), \(state.raisesToday)× hochgefahren")
        return lines
    }

    var isDisabledToday: Bool {
        state.disabledDay == state.day && !state.day.isEmpty
    }

    var isSnoozed: Bool {
        state.snoozeUntil.map { now < $0 } ?? false
    }
}

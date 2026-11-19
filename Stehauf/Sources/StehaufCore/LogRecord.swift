import Foundation

/// Eine Zeile im Messprotokoll (JSON Lines, eine Datei pro Tag).
///
/// `kind`:
/// - `sample`: regelmäßiger Messpunkt mit allen Rohsignalen und der Ableitung
/// - `decision`: Entscheidung des Regelwerks
/// - `feedback`: vom Nutzer markierter Fehler der Erkennung
/// - `desk`: Meldungen der Bluetooth-Verbindung
/// - `app`: Start und Ende der App
public struct LogRecord: Codable, Equatable {
    public var t: String
    public var kind: String
    public var message: String?
    public var signals: Signals?
    public var assessment: Assessment?
    public var phase: String?
    public var blocked: String?
    public var sitStreak: Double?
    public var standStreak: Double?

    public init(t: String, kind: String, message: String? = nil) {
        self.t = t
        self.kind = kind
        self.message = message
    }

    public mutating func attach(signals: Signals, assessment: Assessment, state: EngineState) {
        self.signals = signals
        self.assessment = assessment
        phase = state.phase.rawValue
        blocked = state.blocked
        sitStreak = state.sitStreak.rounded()
        standStreak = state.standStreak.rounded()
    }
}

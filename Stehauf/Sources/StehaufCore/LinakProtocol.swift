import Foundation

/// Bluetooth-Protokoll der LINAK-Tischsteuerungen (DPG-Bedienpanels).
///
/// Portiert aus dem Python-Code in `linak_controller/gatt.py` und
/// `linak_controller/desk.py`. Dieser Teil ist reine Byte-Kodierung und
/// enthält keinen Bluetooth-Zugriff.
public enum Linak {
    public static let controlService = "99FA0001-338A-1024-8A49-009C0215F78A"
    public static let commandCharacteristic = "99FA0002-338A-1024-8A49-009C0215F78A"
    public static let dpgService = "99FA0010-338A-1024-8A49-009C0215F78A"
    public static let dpgCharacteristic = "99FA0011-338A-1024-8A49-009C0215F78A"
    public static let referenceOutputService = "99FA0020-338A-1024-8A49-009C0215F78A"
    public static let heightSpeedCharacteristic = "99FA0021-338A-1024-8A49-009C0215F78A"
    public static let referenceInputService = "99FA0030-338A-1024-8A49-009C0215F78A"
    public static let targetHeightCharacteristic = "99FA0031-338A-1024-8A49-009C0215F78A"

    public enum Command: UInt8 {
        case moveDown = 70
        case moveUp = 71
        case wakeup = 254
        case stop = 255
    }

    public enum DPGCommand: UInt8 {
        case capabilities = 128
        case baseOffset = 129
        case userID = 134
    }

    /// Befehl für die Command-Characteristic.
    public static func encode(_ command: Command) -> Data {
        Data([command.rawValue, 0])
    }

    /// Zielhöhe für die Reference-Input-Characteristic (Zehntelmillimeter über
    /// der untersten Position, little endian).
    public static func encodeTarget(raw: UInt16) -> Data {
        Data([UInt8(raw & 0xFF), UInt8(raw >> 8)])
    }

    /// Höhe (Zehntelmillimeter über der untersten Position) und
    /// Geschwindigkeit (Hundertstelmillimeter pro Sekunde, mit Vorzeichen).
    public static func decodeHeightSpeed(_ data: Data) -> (raw: UInt16, speed: Int16)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let raw = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let speed = Int16(bitPattern: UInt16(bytes[2]) | (UInt16(bytes[3]) << 8))
        return (raw, speed)
    }

    /// Leseanfrage an die DPG-Characteristic.
    public static func dpgRead(_ command: DPGCommand) -> Data {
        Data([0x7F, command.rawValue, 0x00])
    }

    /// Schreibanfrage an die DPG-Characteristic.
    public static func dpgWrite(_ command: DPGCommand, payload: Data) -> Data {
        Data([0x7F, command.rawValue, 0x80]) + payload
    }

    /// Nutzdaten einer DPG-Antwort oder `nil`, wenn die Antwort ungültig ist.
    public static func dpgPayload(_ response: Data) -> Data? {
        let bytes = [UInt8](response)
        guard bytes.count >= 2, bytes[0] == 1 else { return nil }
        return Data(bytes[2...])
    }

    /// Höhe der untersten Position über dem Boden in Millimetern, gelesen aus
    /// den Nutzdaten der `baseOffset`-Antwort.
    public static func baseHeightMM(fromPayload payload: Data) -> Double? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 3 else { return nil }
        let tenths = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        return (Double(tenths) / 10).rounded()
    }

    /// Nutzdaten für das Setzen der User-ID oder `nil`, wenn nichts zu tun ist.
    /// Beim DPG1C muss das erste Byte 1 sein, sonst nimmt der Tisch keine
    /// Fahrbefehle an.
    public static func correctedUserID(fromPayload payload: Data) -> Data? {
        var bytes = [UInt8](payload)
        guard !bytes.isEmpty, bytes[0] != 1 else { return nil }
        bytes[0] = 1
        return Data(bytes)
    }

    public static func mm(raw: UInt16, baseMM: Double) -> Double {
        baseMM + Double(raw) / 10
    }

    public static func raw(mm: Double, baseMM: Double) -> UInt16 {
        let value = ((mm - baseMM) * 10).rounded()
        return UInt16(min(max(value, 0), 65535))
    }
}

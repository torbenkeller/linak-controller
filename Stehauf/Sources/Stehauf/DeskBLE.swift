import CoreBluetooth
import Foundation
import StehaufCore

/// Bluetooth-Verbindung zum Tisch. Läuft vollständig auf der Main-Queue.
///
/// Sicherheit: Der Tisch fährt nur, solange alle 0,4 Sekunden ein neuer
/// Fahrbefehl kommt. Stürzt die App ab oder bricht die Verbindung ab, bleibt
/// er nach etwa einer Sekunde von selbst stehen.
final class DeskBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Status: String {
        case bluetoothOff, unauthorized, searching, searchPaused, connecting, initialising, ready
    }

    /// Ein Scan kostet Strom. Findet er nichts, hört er nach dieser Zeit auf,
    /// bis die Suche im Statusfenster neu gestartet wird.
    private static let scanSeconds: Double = 120

    private enum HandshakeStep {
        case read(Linak.DPGCommand)
        case writeUserID(Data)
    }

    private(set) var status: Status = .searching {
        didSet {
            guard oldValue != status else { return }
            onLog?("Status: \(status.rawValue)")
            onChange?()
        }
    }
    private(set) var heightMM: Double?
    private(set) var speed: Int16 = 0
    private(set) var baseMM: Double
    private(set) var baseKnown = false
    private(set) var name: String?
    private(set) var identifier: UUID?

    /// Nur mit diesem Tisch verbinden. `nil` heißt: den ersten gefundenen
    /// LINAK-Tisch nehmen.
    var preferredIdentifier: UUID?
    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?

    var isMoving: Bool {
        if moveTimer != nil { return true }
        guard let last = lastUpdate else { return false }
        return speed != 0 && Date().timeIntervalSince(last) < 1.5
    }

    private let controlUUID = CBUUID(string: Linak.controlService)
    private let commandUUID = CBUUID(string: Linak.commandCharacteristic)
    private let dpgServiceUUID = CBUUID(string: Linak.dpgService)
    private let dpgUUID = CBUUID(string: Linak.dpgCharacteristic)
    private let outputServiceUUID = CBUUID(string: Linak.referenceOutputService)
    private let heightUUID = CBUUID(string: Linak.heightSpeedCharacteristic)
    private let inputServiceUUID = CBUUID(string: Linak.referenceInputService)
    private let targetUUID = CBUUID(string: Linak.targetHeightCharacteristic)

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rejected: Set<UUID> = []
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var rawHeight: UInt16?
    private var lastUpdate: Date?

    private var scanTimer: Timer?

    private var handshake: [HandshakeStep] = []
    private var handshakeStarted = false
    private var awaiting: HandshakeStep?
    private var handshakeTimer: Timer?

    private var moveTimer: Timer?
    private var moveTarget: UInt16?
    private var moveStarted: Date?
    private var moveCompletion: (() -> Void)?

    init(fallbackBaseMM: Double) {
        baseMM = fallbackBaseMM
        super.init()
    }

    /// Startet Bluetooth. Löst beim ersten Mal die Berechtigungsabfrage aus.
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Trennt die Verbindung und sucht neu, z. B. nach „Tisch vergessen“.
    func restart() {
        endMove(completed: false)
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        rejected.removeAll()
        reset()
        search()
    }

    // MARK: Fahren

    func move(toMM target: Double, completion: (() -> Void)? = nil) {
        guard status == .ready, let command = characteristics[commandUUID] else {
            completion?()
            return
        }
        endMove(completed: false)
        write(command, Linak.encode(.wakeup))
        write(command, Linak.encode(.stop))
        moveTarget = Linak.raw(mm: target, baseMM: baseMM)
        moveStarted = Date()
        moveCompletion = completion
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.moveTick() }
        RunLoop.main.add(timer, forMode: .common)
        moveTimer = timer
        moveTick()
        onChange?()
    }

    /// Kurzer Stupser: ein Stück in die Richtung und zurück zur Ausgangshöhe.
    func nudge(_ direction: Direction, mm: Double) {
        guard status == .ready, moveTimer == nil, let origin = heightMM else { return }
        let offset = direction == .up ? mm : -mm
        move(toMM: origin + offset) { [weak self] in
            self?.move(toMM: origin)
        }
    }

    func stop() {
        endMove(completed: false)
        if status == .ready, let command = characteristics[commandUUID] {
            write(command, Linak.encode(.stop))
        }
    }

    private func moveTick() {
        guard
            status == .ready, let peripheral, let target = moveTarget, let started = moveStarted,
            let input = characteristics[targetUUID], let output = characteristics[heightUUID]
        else {
            endMove(completed: false)
            return
        }
        let age = Date().timeIntervalSince(started)
        if age > 1.2, let last = lastUpdate, last.timeIntervalSince(started) > 0.8, speed == 0 {
            endMove(completed: true)
            return
        }
        if age > 60 {
            onLog?("Fahrt nach 60 s abgebrochen")
            stop()
            return
        }
        write(input, Linak.encodeTarget(raw: target))
        peripheral.readValue(for: output)
    }

    private func endMove(completed: Bool) {
        guard moveTimer != nil else { return }
        moveTimer?.invalidate()
        moveTimer = nil
        moveTarget = nil
        moveStarted = nil
        let completion = moveCompletion
        moveCompletion = nil
        if completed { completion?() }
        onChange?()
    }

    private func write(_ characteristic: CBCharacteristic, _ data: Data) {
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral?.writeValue(data, for: characteristic, type: type)
    }

    // MARK: Suchen und Verbinden

    private func search() {
        guard let central, central.state == .poweredOn else { return }
        status = .searching
        if let preferred = preferredIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [preferred]).first {
            connect(known)
            return
        }
        // Gekoppelte Geräte sind oft schon mit dem System verbunden und
        // tauchen dann in keinem Scan auf.
        let connected = central.retrieveConnectedPeripherals(withServices: [controlUUID])
        if let candidate = connected.first(where: { accepts($0.identifier) }) {
            connect(candidate)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        scanTimer?.invalidate()
        let timer = Timer(timeInterval: DeskBLE.scanSeconds, repeats: false) { [weak self] _ in
            guard let self, self.status == .searching, self.peripheral == nil else { return }
            self.central?.stopScan()
            self.onLog?("Kein Tisch gefunden, Suche pausiert")
            self.status = .searchPaused
        }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    private func accepts(_ id: UUID) -> Bool {
        if rejected.contains(id) { return false }
        if let preferred = preferredIdentifier { return preferred == id }
        return true
    }

    private func connect(_ candidate: CBPeripheral) {
        central?.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        peripheral = candidate
        candidate.delegate = self
        status = .connecting
        // Ohne Zeitlimit: Die Verbindung kommt zustande, sobald der Tisch in
        // Reichweite ist, z. B. wenn der Mac wieder zu Hause steht.
        central?.connect(candidate, options: nil)
    }

    private func reject(_ candidate: CBPeripheral, reason: String) {
        onLog?("Gerät \(candidate.name ?? "?") abgelehnt: \(reason)")
        rejected.insert(candidate.identifier)
        central?.cancelPeripheralConnection(candidate)
        reset()
        search()
    }

    private func reset() {
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        handshake = []
        handshakeStarted = false
        awaiting = nil
        characteristics = [:]
        pendingServices = 0
        peripheral = nil
        heightMM = nil
        rawHeight = nil
        speed = 0
        lastUpdate = nil
        onChange?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            search()
        case .unauthorized:
            endMove(completed: false)
            reset()
            status = .unauthorized
        default:
            endMove(completed: false)
            reset()
            status = .bluetoothOff
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover candidate: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard peripheral == nil, accepts(candidate.identifier) else { return }
        if preferredIdentifier == nil {
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? candidate.name ?? ""
            guard services.contains(controlUUID) || advertisedName.lowercased().hasPrefix("desk") else { return }
        }
        connect(candidate)
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        status = .initialising
        name = connected.name
        connected.discoverServices([controlUUID, dpgServiceUUID, outputServiceUUID, inputServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        onLog?("Verbindung fehlgeschlagen: \(error?.localizedDescription ?? "unbekannt")")
        reset()
        retrySoon()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral gone: CBPeripheral, error: Error?) {
        guard gone.identifier == peripheral?.identifier else { return }
        onLog?("Verbindung getrennt: \(error?.localizedDescription ?? "ohne Fehler")")
        endMove(completed: false)
        reset()
        retrySoon()
    }

    private func retrySoon() {
        status = .searching
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.peripheral == nil else { return }
            self.search()
        }
    }

    // MARK: Dienste und Handshake

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard services.contains(where: { $0.uuid == controlUUID }) else {
            reject(peripheral, reason: "kein LINAK-Steuerdienst")
            return
        }
        pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        pendingServices -= 1
        guard pendingServices == 0 else { return }

        guard let output = characteristics[heightUUID], characteristics[commandUUID] != nil,
              characteristics[targetUUID] != nil
        else {
            reject(peripheral, reason: "Characteristics fehlen")
            return
        }
        peripheral.setNotifyValue(true, for: output)
        peripheral.readValue(for: output)

        if let dpg = characteristics[dpgUUID] {
            handshake = [.read(.capabilities), .read(.userID), .read(.baseOffset)]
            peripheral.setNotifyValue(true, for: dpg)
            // Falls die Bestätigung der Benachrichtigungen ausbleibt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.status == .initialising, !self.handshakeStarted else { return }
                self.onLog?("Handshake übersprungen: keine Benachrichtigungen")
                self.finishInit()
            }
        } else {
            finishInit()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { onLog?("Benachrichtigungen für \(characteristic.uuid): \(error.localizedDescription)") }
        guard characteristic.uuid == dpgUUID, status == .initialising, !handshakeStarted else { return }
        handshakeStarted = true
        nextHandshakeStep()
    }

    private func nextHandshakeStep() {
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        guard !handshake.isEmpty, let dpg = characteristics[dpgUUID] else {
            awaiting = nil
            finishInit()
            return
        }
        let step = handshake.removeFirst()
        awaiting = step
        switch step {
        case .read(let command):
            write(dpg, Linak.dpgRead(command))
        case .writeUserID(let payload):
            write(dpg, Linak.dpgWrite(.userID, payload: payload))
        }
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            self?.onLog?("Handshake-Schritt ohne Antwort")
            self?.nextHandshakeStep()
        }
        RunLoop.main.add(timer, forMode: .common)
        handshakeTimer = timer
    }

    private func handleDPG(_ data: Data) {
        guard let step = awaiting else { return }
        awaiting = nil
        if case .read(let command) = step, let payload = Linak.dpgPayload(data) {
            switch command {
            case .capabilities:
                onLog?("Capabilities: \(payload.map { String(format: "%02x", $0) }.joined(separator: " "))")
            case .userID:
                if let corrected = Linak.correctedUserID(fromPayload: payload) {
                    onLog?("User-ID wird korrigiert")
                    handshake.insert(.writeUserID(corrected), at: 0)
                }
            case .baseOffset:
                if let base = Linak.baseHeightMM(fromPayload: payload), (300...1200).contains(base) {
                    baseMM = base
                    baseKnown = true
                    if let raw = rawHeight { heightMM = Linak.mm(raw: raw, baseMM: base) }
                    onLog?("Unterste Höhe: \(Int(base)) mm")
                }
            }
        }
        nextHandshakeStep()
    }

    private func finishInit() {
        guard status == .initialising, let peripheral else { return }
        identifier = peripheral.identifier
        if !baseKnown { onLog?("Unterste Höhe nicht gemeldet, nehme \(Int(baseMM)) mm an") }
        status = .ready
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onLog?("Lesen von \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == heightUUID {
            guard let decoded = Linak.decodeHeightSpeed(data) else { return }
            rawHeight = decoded.raw
            speed = decoded.speed
            lastUpdate = Date()
            heightMM = Linak.mm(raw: decoded.raw, baseMM: baseMM)
            onChange?()
        } else if characteristic.uuid == dpgUUID {
            handleDPG(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { onLog?("Schreiben auf \(characteristic.uuid): \(error.localizedDescription)") }
    }
}

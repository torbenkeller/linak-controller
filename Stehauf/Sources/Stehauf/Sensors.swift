import AppKit
import CoreAudio
import CoreGraphics
import CoreMediaIO
import EventKit
import Foundation

/// Zeit seit der letzten Tastatur- oder Mauseingabe.
enum InputIdle {
    private static let types: [CGEventType] = [
        .keyDown, .flagsChanged, .mouseMoved, .scrollWheel,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged,
    ]

    /// `.hidSystemState` zählt Eingaben von echter Hardware,
    /// `.combinedSessionState` zusätzlich von Programmen erzeugte Eingaben.
    static func seconds(_ state: CGEventSourceStateID) -> Double {
        let values = types.map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }
        return ((values.min() ?? 0) * 10).rounded() / 10
    }
}

/// Welche Apps gerade vom Mikrofon aufnehmen.
enum MicrophoneSensor {
    struct Reading {
        var apps: [String] = []
        /// Ein reines Eingabegerät läuft, auch wenn keine App zugeordnet werden konnte.
        var inputDeviceRunning = false
        var inUse: Bool { !apps.isEmpty || inputDeviceRunning }
    }

    static func read() -> Reading {
        var reading = Reading()
        let system = AudioObjectID(kAudioObjectSystemObject)

        let processes = objectIDs(system, AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList))
        for process in processes {
            guard uint32(process, AudioObjectPropertySelector(kAudioProcessPropertyIsRunningInput)) == 1 else { continue }
            reading.apps.append(label(for: process))
        }
        reading.apps = Array(Set(reading.apps)).sorted()

        // Geräte mit Ein- und Ausgang (z. B. USB-Headsets) laufen auch bei
        // reiner Wiedergabe. Deshalb zählen hier nur reine Eingabegeräte.
        for device in objectIDs(system, AudioObjectPropertySelector(kAudioHardwarePropertyDevices)) {
            let inputs = streamCount(device, scope: kAudioObjectPropertyScopeInput)
            let outputs = streamCount(device, scope: kAudioObjectPropertyScopeOutput)
            guard inputs > 0, outputs == 0 else { continue }
            if uint32(device, AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere)) == 1 {
                reading.inputDeviceRunning = true
            }
        }
        return reading
    }

    private static func label(for process: AudioObjectID) -> String {
        if let bundle = string(process, AudioObjectPropertySelector(kAudioProcessPropertyBundleID)), !bundle.isEmpty {
            return bundle
        }
        if let pid = uint32(process, AudioObjectPropertySelector(kAudioProcessPropertyPID)) {
            let app = NSRunningApplication(processIdentifier: pid_t(pid))
            return app?.bundleIdentifier ?? app?.localizedName ?? "pid:\(pid)"
        }
        return "unbekannt"
    }

    private static func makeAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = makeAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = makeAddress(AudioObjectPropertySelector(kAudioDevicePropertyStreams), scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = makeAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = makeAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Ob irgendeine Kamera gerade läuft.
enum CameraSensor {
    static func inUse() -> Bool {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }

        for device in devices {
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var running: UInt32 = 0
            var usedBytes: UInt32 = 0
            let status = CMIOObjectGetPropertyData(
                device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &usedBytes, &running
            )
            if status == 0, running != 0 { return true }
        }
        return false
    }
}

/// Kalendertermine: läuft gerade einer, und wann beginnt der nächste.
final class CalendarSensor {
    private let store = EKEventStore()
    private var intervals: [DateInterval] = []
    private var lastFetch = Date.distantPast

    /// Ohne Beschreibungstext im Info.plist beendet macOS die App beim
    /// Kalenderzugriff. Das betrifft Starts ohne App-Bundle (`swift run`).
    private var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil
    }

    var authorized: Bool {
        hasUsageDescription && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        guard hasUsageDescription else {
            completion(false)
            return
        }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func read(now: Date, requireAttendees: Bool) -> (busy: Bool, minutesToNext: Double?) {
        guard authorized else { return (false, nil) }
        if now.timeIntervalSince(lastFetch) > 60 {
            lastFetch = now
            let predicate = store.predicateForEvents(
                withStart: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(3 * 3600), calendars: nil
            )
            intervals = store.events(matching: predicate).compactMap { event in
                guard !event.isAllDay, event.status != .canceled, event.availability != .free else { return nil }
                if requireAttendees && !event.hasAttendees { return nil }
                let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
                guard !declined, event.endDate > event.startDate else { return nil }
                return DateInterval(start: event.startDate, end: event.endDate)
            }
        }
        let busy = intervals.contains { $0.contains(now) }
        let next = intervals.map(\.start).filter { $0 > now }.min()
        let minutes = next.map { ($0.timeIntervalSince(now) / 60 * 10).rounded() / 10 }
        return (busy, minutes)
    }
}

/// Bildschirmsperre und Ruhezustand des Displays.
final class ScreenSensor {
    private(set) var locked = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
        })
    }
}

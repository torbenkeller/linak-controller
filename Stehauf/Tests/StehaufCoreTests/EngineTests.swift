import XCTest
@testable import StehaufCore

/// Spielt dem Regelwerk Sekunde für Sekunde Signale vor.
private struct Simulation {
    var engine: Engine
    var detector = Detector()
    var now = Date(timeIntervalSince1970: 1_800_000_000) // 08:00 UTC
    var signals = Signals()
    /// Wenn `false`, wächst die Zeit seit der letzten Eingabe mit jeder Sekunde.
    var typing = true
    /// Abstand zwischen zwei Schritten des Regelwerks in Sekunden.
    var tick = 1
    var assessment = Assessment()

    init(config: Config = Config(), confirmed: Bool = true) {
        var config = config
        // Die Tests beschreiben Abläufe mit 60 s Countdown.
        config.countdownSeconds = 60
        config.sitHeightConfirmed = confirmed
        config.standHeightConfirmed = confirmed
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        engine = Engine(config: config, calendar: calendar)
        signals.deskConnected = true
        signals.deskHeightMM = config.sitHeightMM
        signals.idleSeconds = 1
    }

    @discardableResult
    mutating func run(seconds: Int) -> [Action] {
        var all: [Action] = []
        for _ in 0..<(seconds / tick) {
            now = now.addingTimeInterval(Double(tick))
            signals.idleSeconds = typing ? 1 : signals.idleSeconds + Double(tick)
            assessment = detector.assess(signals, now: now, config: engine.config)
            all.append(contentsOf: engine.step(signals: signals, assessment: assessment, now: now))
        }
        return all
    }

    /// Läuft, bis die Phase erreicht ist (höchstens `limit` Sekunden).
    @discardableResult
    mutating func run(until phase: Phase, limit: Int = 4 * 60 * 60) -> [Action] {
        var all: [Action] = []
        for _ in 0..<limit where engine.state.phase != phase {
            all.append(contentsOf: run(seconds: 1))
        }
        return all
    }

    @discardableResult
    mutating func user(_ action: UserAction) -> [Action] {
        engine.handle(action, signals: signals, assessment: assessment, now: now)
    }

    /// Simuliert, dass der Tisch die Fahrt ausführt und am Ziel ankommt.
    mutating func completeMove(toMM height: Double) {
        signals.deskMoving = true
        run(seconds: 5)
        signals.deskHeightMM = height
        signals.deskMoving = false
        run(seconds: 2)
    }

    var phase: Phase { engine.state.phase }
}

private func moves(_ actions: [Action]) -> [Action] {
    actions.filter { if case .move = $0 { return true } else { return false } }
}

final class EngineTests: XCTestCase {
    func testRaisesAfterSitIntervalAndLowersAfterStandInterval() {
        var sim = Simulation()
        let quiet = sim.run(seconds: 44 * 60)
        XCTAssertEqual(sim.phase, .sitting)
        XCTAssertTrue(moves(quiet).isEmpty)

        let announce = sim.run(seconds: 90)
        XCTAssertEqual(sim.phase, .announcingUp)
        XCTAssertTrue(announce.contains(.nudge(.up)))

        let afterCountdown = sim.run(until: .movingUp, limit: 61)
        XCTAssertEqual(moves(afterCountdown), [.move(.up, targetMM: 1100)])

        sim.completeMove(toMM: 1100)
        XCTAssertEqual(sim.phase, .standing)
        XCTAssertEqual(sim.engine.state.raisesToday, 1)

        sim.run(seconds: 19 * 60)
        XCTAssertEqual(sim.phase, .standing)
        sim.run(seconds: 90)
        XCTAssertEqual(sim.phase, .announcingDown)
        let down = sim.run(until: .movingDown, limit: 61)
        XCTAssertEqual(moves(down), [.move(.down, targetMM: 720)])

        sim.completeMove(toMM: 720)
        XCTAssertEqual(sim.phase, .sitting)
        XCTAssertLessThan(sim.engine.state.sitStreak, 10)
    }

    func testDoesNotMoveWithoutInputDuringCountdown() {
        var sim = Simulation()
        sim.run(until: .announcingUp)

        sim.typing = false
        let waiting = sim.run(seconds: 120)
        XCTAssertTrue(moves(waiting).isEmpty)
        XCTAssertTrue(sim.engine.state.waitingForPresence)

        sim.typing = true
        let resumed = sim.run(seconds: 15)
        XCTAssertEqual(moves(resumed).count, 1)
    }

    func testAnnouncementIsCancelledWhenUserStaysAway() {
        var sim = Simulation()
        sim.run(until: .announcingUp)
        sim.typing = false
        let away = sim.run(seconds: 400)
        XCTAssertTrue(moves(away).isEmpty)
        XCTAssertEqual(sim.phase, .away)

        sim.typing = true
        sim.run(seconds: 3)
        XCTAssertEqual(sim.phase, .announcingUp)
    }

    func testStaysInactiveWithoutDesk() {
        var sim = Simulation()
        sim.signals.deskConnected = false
        let actions = sim.run(seconds: 3 * 60 * 60)
        XCTAssertEqual(sim.phase, .inactive)
        XCTAssertTrue(moves(actions).isEmpty)
        XCTAssertEqual(sim.engine.state.sitStreak, 0)
    }

    func testMeetingBlocksAndAnnouncesAfterwards() {
        var sim = Simulation()
        sim.signals.micApps = ["com.microsoft.teams2"]
        sim.signals.micInUse = true
        sim.run(seconds: 50 * 60)
        XCTAssertEqual(sim.phase, .sitting)
        XCTAssertEqual(sim.engine.state.blocked, "meeting")

        sim.signals.micApps = []
        sim.signals.micInUse = false
        sim.run(seconds: 30)
        XCTAssertEqual(sim.engine.state.blocked, "meeting-just-ended")
        sim.run(seconds: 40)
        XCTAssertEqual(sim.phase, .announcingUp)
    }

    func testMeetingStartingDuringCountdownCancels() {
        var sim = Simulation()
        sim.run(seconds: 45 * 60 + 5)
        XCTAssertEqual(sim.phase, .announcingUp)
        sim.signals.cameraInUse = true
        let actions = sim.run(seconds: 120)
        XCTAssertTrue(moves(actions).isEmpty)
        XCTAssertEqual(sim.phase, .sitting)
    }

    func testDictationDoesNotBlock() {
        var sim = Simulation()
        sim.signals.micApps = ["com.goodsnooze.MacWhisper"]
        sim.signals.micInUse = true
        sim.run(seconds: 45 * 60 + 5)
        XCTAssertEqual(sim.phase, .announcingUp)
    }

    func testCalendarLeadTimeBlocksRaising() {
        var sim = Simulation()
        sim.signals.minutesToNextMeeting = 3
        sim.run(seconds: 46 * 60)
        XCTAssertEqual(sim.engine.state.blocked, "meeting-soon")
        sim.signals.minutesToNextMeeting = nil
        sim.run(seconds: 3)
        XCTAssertEqual(sim.phase, .announcingUp)
    }

    func testSnoozeAndNotToday() {
        var sim = Simulation()
        sim.run(seconds: 45 * 60 + 5)
        sim.user(.snooze)
        XCTAssertEqual(sim.phase, .sitting)
        sim.run(seconds: 14 * 60)
        XCTAssertEqual(sim.engine.state.blocked, "snoozed")
        sim.run(seconds: 90)
        XCTAssertEqual(sim.phase, .announcingUp)

        sim.user(.notToday)
        sim.run(seconds: 60 * 60)
        XCTAssertEqual(sim.engine.state.blocked, "disabled-today")
        sim.user(.resume)
        sim.run(seconds: 3)
        XCTAssertEqual(sim.phase, .announcingUp)
    }

    func testGoNowMovesImmediately() {
        var sim = Simulation()
        sim.run(seconds: 45 * 60 + 5)
        XCTAssertEqual(moves(sim.user(.goNow)), [.move(.up, targetMM: 1100)])
        XCTAssertEqual(sim.phase, .movingUp)
    }

    func testManualRaiseCountsAsStanding() {
        var sim = Simulation()
        sim.run(seconds: 30 * 60)
        sim.signals.deskHeightMM = 1100
        sim.run(seconds: 6 * 60)
        XCTAssertEqual(sim.phase, .standing)
        sim.signals.deskHeightMM = 720
        sim.run(seconds: 5)
        XCTAssertEqual(sim.phase, .sitting)
        XCTAssertLessThan(sim.engine.state.sitStreak, 10)
    }

    func testShortStandDoesNotResetSitTimer() {
        var sim = Simulation()
        sim.run(seconds: 30 * 60)
        sim.signals.deskHeightMM = 1100
        sim.run(seconds: 60)
        sim.signals.deskHeightMM = 720
        sim.run(seconds: 5)
        XCTAssertGreaterThan(sim.engine.state.sitStreak, 29 * 60)
    }

    func testShortAbsencePausesTimerAndWaitsAfterReturn() {
        var sim = Simulation()
        sim.run(seconds: 44 * 60)
        let before = sim.engine.state.sitStreak

        sim.typing = false
        sim.signals.idleSeconds = 1000
        sim.run(seconds: 10 * 60)
        XCTAssertEqual(sim.phase, .away)
        XCTAssertEqual(sim.engine.state.sitStreak, before, accuracy: 1)

        // Zurück: Die Sitzzeit wäre nach einer Minute fällig, aber wer gerade
        // erst wieder anfängt, bekommt eine Schonfrist.
        sim.typing = true
        sim.run(seconds: 3 * 60)
        XCTAssertEqual(sim.phase, .sitting)
        XCTAssertEqual(sim.engine.state.blocked, "just-returned")

        sim.run(until: .announcingUp, limit: 3 * 60)
        XCTAssertEqual(sim.phase, .announcingUp)
    }

    func testLongBreakResetsSitClock() {
        var sim = Simulation()
        sim.run(seconds: 44 * 60)

        // Über Nacht weg.
        sim.typing = false
        sim.signals.idleSeconds = 1000
        sim.tick = 60
        sim.run(seconds: 20 * 60 * 60)
        sim.tick = 1

        sim.typing = true
        let actions = sim.run(seconds: 30 * 60)
        XCTAssertTrue(actions.contains(.note("Lange Pause, Sitz-Uhr beginnt neu")))
        XCTAssertEqual(sim.phase, .sitting)
        XCTAssertEqual(sim.engine.state.sitStreak, 30 * 60, accuracy: 2)
    }

    func testFailedMoveSnoozes() {
        var sim = Simulation()
        sim.run(seconds: 45 * 60 + 5)
        sim.user(.goNow)
        // Tisch bewegt sich nicht (z. B. Kollisionsschutz).
        let actions = sim.run(seconds: 10)
        XCTAssertEqual(sim.phase, .sitting)
        XCTAssertTrue(actions.contains(.note("Fahrt abgebrochen: Tisch hat vor dem Ziel angehalten")))
        sim.run(seconds: 60)
        XCTAssertEqual(sim.engine.state.blocked, "snoozed")
    }

    func testSlowTicksCountFullTime() {
        var sim = Simulation()
        sim.tick = 10
        sim.run(seconds: 44 * 60)
        XCTAssertEqual(sim.engine.state.sitStreak, 44 * 60 - 10, accuracy: 1)
        XCTAssertEqual(sim.phase, .sitting)
        sim.run(seconds: 2 * 60)
        XCTAssertEqual(sim.phase, .announcingUp)
    }

    func testNeverMovesBeforeHeightsAreConfirmed() {
        var sim = Simulation(confirmed: false)
        let actions = sim.run(seconds: 2 * 60 * 60)
        XCTAssertTrue(moves(actions).isEmpty)
        XCTAssertEqual(sim.phase, .sitting)
        XCTAssertEqual(sim.engine.state.blocked, "setup")
        XCTAssertTrue(sim.user(.raise).isEmpty)
    }

    func testAutoDownCanBeDisabled() {
        var config = Config()
        config.autoDown = false
        var sim = Simulation(config: config)
        sim.signals.deskHeightMM = 1100
        let actions = sim.run(seconds: 2 * 60 * 60)
        XCTAssertEqual(sim.phase, .standing)
        XCTAssertTrue(moves(actions).isEmpty)
    }

    func testDailyCountersResetAtMidnight() {
        var sim = Simulation()
        sim.run(seconds: 60)
        XCTAssertGreaterThan(sim.engine.state.sitSecondsToday, 50)
        sim.now = sim.now.addingTimeInterval(17 * 60 * 60)
        sim.run(seconds: 2)
        XCTAssertLessThan(sim.engine.state.sitSecondsToday, 5)
    }
}

final class DetectorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testPostureFollowsDeskHeight() {
        var detector = Detector()
        var signals = Signals()
        signals.deskConnected = true
        signals.deskHeightMM = 720
        XCTAssertEqual(detector.assess(signals, now: start, config: Config()).posture, .sitting)
        signals.deskHeightMM = 1090
        XCTAssertEqual(detector.assess(signals, now: start, config: Config()).posture, .standing)
        signals.deskHeightMM = nil
        XCTAssertEqual(detector.assess(signals, now: start, config: Config()).posture, .unknown)
    }

    func testClassifiesMicApps() {
        let config = Config()
        XCTAssertEqual(Detector.classify("com.goodsnooze.MacWhisper", config: config), .ignored)
        XCTAssertEqual(Detector.classify("com.google.Chrome.helper", config: config), .meeting)
        XCTAssertEqual(Detector.classify("com.tinyspeck.slackmacgap.helper", config: config), .meeting)
        XCTAssertEqual(Detector.classify("com.example.recorder", config: config), .unknown)
    }

    func testUnknownMicAppCountsOnlyWhenSustained() {
        var detector = Detector()
        var signals = Signals()
        signals.micApps = ["com.example.recorder"]
        signals.micInUse = true
        XCTAssertFalse(detector.assess(signals, now: start, config: Config()).inMeeting)
        let later = detector.assess(signals, now: start.addingTimeInterval(121), config: Config())
        XCTAssertEqual(later.meetingReasons, ["mic-sustained"])
    }

    func testLongDictationIsNotAMeeting() {
        var detector = Detector()
        var signals = Signals()
        signals.micApps = ["com.goodsnooze.MacWhisper"]
        signals.micInUse = true
        _ = detector.assess(signals, now: start, config: Config())
        XCTAssertFalse(detector.assess(signals, now: start.addingTimeInterval(600), config: Config()).inMeeting)
    }

    func testCameraAndCalendar() {
        var detector = Detector()
        var signals = Signals()
        signals.idleSeconds = 1000
        signals.calendarBusy = true
        let calendarOnly = detector.assess(signals, now: start, config: Config())
        XCTAssertTrue(calendarOnly.inMeeting)
        XCTAssertFalse(calendarOnly.present, "Ein Kalendereintrag allein beweist keine Anwesenheit")

        signals.cameraInUse = true
        let withCamera = detector.assess(signals, now: start, config: Config())
        XCTAssertEqual(withCamera.meetingReasons, ["camera", "calendar"])
        XCTAssertTrue(withCamera.present)
    }

    func testLockedScreenIsNotPresent() {
        var detector = Detector()
        var signals = Signals()
        signals.idleSeconds = 1
        signals.screenLocked = true
        XCTAssertFalse(detector.assess(signals, now: start, config: Config()).present)
    }
}

final class ProtocolTests: XCTestCase {
    func testCommandsAndTargets() {
        XCTAssertEqual([UInt8](Linak.encode(.stop)), [255, 0])
        XCTAssertEqual([UInt8](Linak.encode(.wakeup)), [254, 0])
        XCTAssertEqual([UInt8](Linak.encodeTarget(raw: 4200)), [0x68, 0x10])
        XCTAssertEqual([UInt8](Linak.dpgRead(.baseOffset)), [0x7F, 129, 0])
        XCTAssertEqual([UInt8](Linak.dpgWrite(.userID, payload: Data([1, 2]))), [0x7F, 134, 0x80, 1, 2])
    }

    func testDecodesHeightAndSignedSpeed() {
        let up = Linak.decodeHeightSpeed(Data([0x68, 0x10, 0x10, 0x0E]))
        XCTAssertEqual(up?.raw, 4200)
        XCTAssertEqual(up?.speed, 3600)
        let down = Linak.decodeHeightSpeed(Data([0x00, 0x00, 0xF0, 0xF1]))
        XCTAssertEqual(down?.speed, -3600)
        XCTAssertNil(Linak.decodeHeightSpeed(Data([1, 2])))
    }

    func testDecodesFromDataSlice() {
        let slice = Data([9, 9, 0x68, 0x10, 0, 0]).dropFirst(2)
        XCTAssertEqual(Linak.decodeHeightSpeed(slice)?.raw, 4200)
    }

    func testDPGResponses() {
        XCTAssertNil(Linak.dpgPayload(Data([0, 3, 1, 2, 3])))
        let payload = Linak.dpgPayload(Data([1, 3, 0, 0x38, 0x18]))
        XCTAssertEqual(payload.map { [UInt8]($0) }, [0, 0x38, 0x18])
        XCTAssertEqual(payload.flatMap { Linak.baseHeightMM(fromPayload: $0) }, 620)

        XCTAssertNil(Linak.correctedUserID(fromPayload: Data([1, 7, 7])))
        XCTAssertEqual(Linak.correctedUserID(fromPayload: Data([0, 7, 7])).map { [UInt8]($0) }, [1, 7, 7])
    }

    func testHeightConversion() {
        XCTAssertEqual(Linak.mm(raw: 4200, baseMM: 620), 1040)
        XCTAssertEqual(Linak.raw(mm: 1040, baseMM: 620), 4200)
        XCTAssertEqual(Linak.raw(mm: 100, baseMM: 620), 0)
    }
}

final class ConfigTests: XCTestCase {
    func testMissingKeysFallBackToDefaults() {
        let config = Config.load(from: Data(#"{"sitMinutes": 30, "nudgeEnabled": false}"#.utf8))
        XCTAssertEqual(config.sitMinutes, 30)
        XCTAssertFalse(config.nudgeEnabled)
        XCTAssertEqual(config.standMinutes, Config().standMinutes)
        XCTAssertEqual(config.meetingAppPatterns, Config().meetingAppPatterns)
        XCTAssertFalse(config.heightsConfirmed)
    }

    func testRoundTrip() {
        var config = Config()
        config.deskIdentifier = "ABC"
        config.activeHoursStart = 8
        XCTAssertEqual(Config.load(from: config.encoded()), config)
    }

    func testGarbageYieldsDefaults() {
        XCTAssertEqual(Config.load(from: Data("nonsense".utf8)), Config())
    }
}

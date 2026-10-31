import Foundation
import Testing
@testable import VoiceItLogic

@Suite("Hotkey state machine")
struct HotkeyMachineTests {
    /// Feeds inputs one by one and returns every action produced.
    func run(_ inputs: [HotkeyMachine.Input], machine: HotkeyMachine = HotkeyMachine()) -> (actions: [HotkeyMachine.Action], state: HotkeyMachine.State) {
        var m = machine
        let actions = inputs.flatMap { m.handle($0) }
        return (actions, m.state)
    }
    func down(_ t: Double, shift: Bool = false) -> HotkeyMachine.Input { .hotkeyDown(shift: shift, at: t) }
    func up(_ t: Double) -> HotkeyMachine.Input { .hotkeyUp(at: t) }

    // MARK: Hold to talk

    @Test func aHoldRecordsThenFinishes() {
        let r = run([down(0), up(1.2)])
        #expect(r.actions == [.startRecording, .finishHold(held: 1.2)])
        #expect(r.state == .idle)
    }

    @Test func aQuickTapDoesNothing() {
        let r = run([down(0), up(0.2)])
        #expect(r.actions == [.startRecording, .discardTap])
        #expect(r.state == .idle)
    }

    @Test func aHoldJustOverTheLimitCounts() {
        #expect(run([down(0), up(0.31)]).actions.last == .finishHold(held: 0.31))
        #expect(run([down(0), up(0.29)]).actions.last == .discardTap)
    }

    @Test func anotherKeyOrEscapeDuringAHoldCancelsIt() {
        #expect(run([down(0), .otherKey]).actions == [.startRecording, .cancel])
        #expect(run([down(0), .escape]).actions == [.startRecording, .cancel])
        let r = run([down(0), .otherKey, up(1)])           // the release after a cancel is ignored
        #expect(r.actions == [.startRecording, .cancel] && r.state == .idle)
    }

    @Test func aSecondCancelAfterTheFirstIsIgnored() {
        // Escape both cancels the hold and reports a key-down: the second event must not do anything.
        #expect(run([down(0), .escape, .otherKey]).actions == [.startRecording, .cancel])
    }

    @Test func aHoldWithoutShiftIsAlwaysAnOrdinaryHold() {
        #expect(run([down(0), .shift(down: false), up(1)]).actions.last == .finishHold(held: 1))
    }

    // MARK: Hands-free

    @Test func shiftDuringAHoldThenReleaseStartsHandsFree() {
        let r = run([down(0), .shift(down: true), up(1), ])
        #expect(r.actions == [.startRecording, .enterHandsFree])
        #expect(r.state == .handsFree)
    }

    @Test func shiftPressedBeforeTheHotkeyAlsoCounts() {
        let r = run([down(0, shift: true), up(1)])
        #expect(r.actions == [.startRecording, .enterHandsFree] && r.state == .handsFree)
    }

    @Test func aQuickOptionShiftPressIsStillHandsFree() {
        let r = run([down(0), .shift(down: true), up(0.1)])
        #expect(r.actions == [.startRecording, .enterHandsFree])      // exempt from the 300 ms tap rule
    }

    @Test func shiftReleasedBeforeTheHotkeyStillCounts() {
        let r = run([down(0), .shift(down: true), .shift(down: false), up(2)])
        #expect(r.actions.last == .enterHandsFree)
    }

    @Test func theHotkeyAgainFinishesHandsFreeAndItsReleaseIsIgnored() {
        var m = HotkeyMachine()
        _ = [down(0), .shift(down: true), up(1)].flatMap { m.handle($0) }
        #expect(m.handle(down(5)) == [.finishHandsFree])
        #expect(m.state == .idle)
        #expect(m.handle(up(5.1)) == [])                    // not a tap, not a new recording
        #expect(m.handle(down(6)) == [.startRecording])     // and the next press works normally
    }

    @Test func doneAndTheAutomaticLimitsFinishHandsFree() {
        for input in [HotkeyMachine.Input.done, .autoStop, .interrupted] {
            var m = HotkeyMachine()
            _ = [down(0), .shift(down: true), up(1)].flatMap { m.handle($0) }
            #expect(m.handle(input) == [.finishHandsFree])
            #expect(m.state == .idle)
        }
    }

    @Test func escapeAndTheXButtonCancelHandsFree() {
        for input in [HotkeyMachine.Input.escape, .cancelButton] {
            var m = HotkeyMachine()
            _ = [down(0), .shift(down: true), up(1)].flatMap { m.handle($0) }
            #expect(m.handle(input) == [.cancel])
            #expect(m.state == .idle)
        }
    }

    @Test func typingAndShiftDuringHandsFreeChangeNothing() {
        var m = HotkeyMachine()
        _ = [down(0), .shift(down: true), up(1)].flatMap { m.handle($0) }
        #expect(m.handle(.otherKey) == [])
        #expect(m.handle(.shift(down: true)) == [])
        #expect(m.handle(.shift(down: false)) == [])
        #expect(m.state == .handsFree)
    }

    @Test func sleepDropsAHoldButKeepsHandsFree() {
        #expect(run([down(0), .interrupted]).actions == [.startRecording, .cancel])
        var m = HotkeyMachine()
        _ = [down(0), .shift(down: true), up(1)].flatMap { m.handle($0) }
        #expect(m.handle(.interrupted) == [.finishHandsFree])
    }

    // MARK: Odd sequences

    @Test func aRecordingThatCouldNotStartLeavesTheMachineIdle() {
        let r = run([down(0), .startFailed, up(1)])
        #expect(r.actions == [.startRecording] && r.state == .idle)
        #expect(run([down(0), .startFailed, down(2)]).actions == [.startRecording, .startRecording])
    }

    @Test func buttonsAndLimitsDoNothingWhenNothingIsRecording() {
        for input in [HotkeyMachine.Input.done, .cancelButton, .autoStop, .interrupted, .escape, .otherKey, .shift(down: true), up(1)] {
            #expect(run([input]).actions == [])
        }
    }

    @Test func aRepeatedKeyDownDuringAHoldIsIgnored() {
        let r = run([down(0), down(0.1), up(1)])
        #expect(r.actions == [.startRecording, .finishHold(held: 1)])
    }

    @Test func manyDictationsInARowEachStartClean() {
        var m = HotkeyMachine()
        for n in 0..<3 {
            let t = Double(n) * 10
            #expect(m.handle(down(t)) == [.startRecording])
            #expect(m.handle(.shift(down: true)) == [])
            #expect(m.handle(up(t + 1)) == [.enterHandsFree])
            #expect(m.handle(.done) == [.finishHandsFree])
            #expect(m.handle(down(t + 5)) == [.startRecording])      // a plain hold afterwards has no leftover Shift
            #expect(m.handle(up(t + 6)) == [.finishHold(held: 1)])
        }
    }
}

@Suite("Copy only")
struct CopyOnlyTests {
    func run(_ inputs: [HotkeyMachine.Input]) -> [HotkeyMachine.Action] {
        var m = HotkeyMachine()
        return inputs.flatMap { m.handle($0) }
    }

    @Test func holdingTheCopyModifierDuringAHoldCopiesInsteadOfPasting() {
        let a = run([.hotkeyDown(shift: false, at: 0), .copyModifier(down: true), .hotkeyUp(at: 1)])
        #expect(a == [.startRecording, .finishHold(held: 1, copyOnly: true)])
    }

    @Test func theCopyModifierHeldBeforeTheHotkeyAlsoCounts() {
        let a = run([.hotkeyDown(shift: false, copy: true, at: 0), .hotkeyUp(at: 1)])
        #expect(a.last == .finishHold(held: 1, copyOnly: true))
    }

    @Test func aPlainHoldStillPastes() {
        #expect(run([.hotkeyDown(shift: false, at: 0), .hotkeyUp(at: 1)]).last == .finishHold(held: 1, copyOnly: false))
    }

    @Test func aQuickCopyTapIsStillATap() {
        #expect(run([.hotkeyDown(shift: false, copy: true, at: 0), .hotkeyUp(at: 0.1)]).last == .discardTap)
    }

    @Test func bothModifiersMeansCopyAndNoHandsFree() {
        let a = run([.hotkeyDown(shift: false, at: 0), .shift(down: true), .copyModifier(down: true), .hotkeyUp(at: 1)])
        #expect(a == [.startRecording, .finishHold(held: 1, copyOnly: true)])
        let b = run([.hotkeyDown(shift: true, copy: true, at: 0), .hotkeyUp(at: 1)])      // both already down at the press
        #expect(b.last == .finishHold(held: 1, copyOnly: true))
        let c = run([.hotkeyDown(shift: true, at: 0), .copyModifier(down: true), .hotkeyUp(at: 1)])   // Shift first, copy later
        #expect(c.last == .finishHold(held: 1, copyOnly: true))
    }

    @Test func copyDoesNotLeakIntoTheNextDictation() {
        var m = HotkeyMachine()
        _ = [HotkeyMachine.Input.hotkeyDown(shift: false, copy: true, at: 0), .hotkeyUp(at: 1)].flatMap { m.handle($0) }
        #expect(m.handle(.hotkeyDown(shift: false, at: 5)) == [.startRecording])
        #expect(m.handle(.hotkeyUp(at: 6)) == [.finishHold(held: 1, copyOnly: false)])
    }

    @Test func theCopyModifierDoesNotCancelAHoldButAnotherKeyStillDoes() {
        #expect(run([.hotkeyDown(shift: false, at: 0), .copyModifier(down: true), .otherKey]) == [.startRecording, .cancel])
    }

    @Test func theCopyModifierDoesNothingOutsideAHold() {
        #expect(run([.copyModifier(down: true)]) == [])
    }
}

@Suite("Copy key setting")
struct CopyKeySettingTests {
    func decode(_ json: String) throws -> Config { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }

    @Test func rightCommandIsTheDefault() throws {
        #expect(Config().copyModifier == .rightCommand)
        #expect(try decode("{}").copyModifier == .rightCommand)
    }

    @Test func itCanBeChanged() throws {
        #expect(try decode(#"{"copyModifier": "rightControl"}"#).copyModifier == .rightControl)
    }

    @Test func itCannotBeTheHotkeyOrShiftOrUnknown() {
        #expect(throws: DecodingError.self) { try decode(#"{"hotkey": "rightCommand"}"#) }                 // the default copy key would clash
        #expect(throws: DecodingError.self) { try decode(#"{"copyModifier": "rightOption"}"#) }            // same as the default hotkey
        #expect(throws: DecodingError.self) { try decode(#"{"copyModifier": "leftShift"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"copyModifier": "capsLock"}"#) }
        #expect((try? decode(#"{"hotkey": "rightCommand", "copyModifier": "rightControl"}"#)) != nil)      // moving both is fine
    }

    @Test func theProblemIsNamedWithItsLine() throws {
        let data = Data("{\n  \"hotkey\": \"rightCommand\"\n}".utf8)
        do { _ = try JSONDecoder().decode(Config.self, from: data); Issue.record("should have thrown") }
        catch {
            let p = ConfigProblem.diagnose(error, in: data)
            #expect(p.message.contains("copyModifier") && p.message.contains("rightCommand"))
        }
    }
}

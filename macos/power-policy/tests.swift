import Foundation
import CoreGraphics

@main
struct PowerPolicyTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }

    static func sample(ac: Bool = false, coffee: Bool = false, closed: Bool = false,
                       disabled: Bool = false, locked: Bool? = true, external: Bool? = false) -> PolicySample {
        PolicySample(externalPower: ac, lidClosed: closed, caffeinate: coffee,
                     sleepDisabled: disabled, screenLocked: locked, externalDisplayConnected: external)
    }

    static func expectUndisturbed(_ actions: [PolicyAction], _ message: String) {
        expect(!actions.contains(.lock) && !actions.contains(.displaySleep) && !actions.contains(.sleep), message)
    }

    // Plans one reading and applies the runtime's sleep-block writes, which
    // land before the next reading.
    static func step(_ engine: inout PolicyEngine, _ input: inout PolicySample, _ now: Double) -> [PolicyAction] {
        let actions = engine.plan(input, now: now)
        if actions.contains(.setSleepDisabled(false)) { input.sleepDisabled = false }
        if actions.contains(.setSleepDisabled(true)) { input.sleepDisabled = true }
        return actions
    }

    // macOS's own idle display sleep: the displays go off after its window
    // with no input, and the immediate password locks the session.
    static func macOSIdleDisplayOff(_ input: inout PolicySample) {
        input.displaysAsleep = true
        input.idleSeconds = 180
        input.screenLocked = true
    }

    // power-policy-truth-table.md, agreed 9 November 2026, with Coffee's
    // Prevent display sleep on. Each row starts as a Mac in use (lid open,
    // displays on, the block held), reads for almost three minutes with no
    // input, then closes the lid for a closed row, then lets macOS's idle
    // display sleep turn the displays off. Screens that "stay on" or "turn off
    // after configured window" are macOS's: the agent must never blank them.
    static func truthTable() throws {
        // number, monitor, Coffee, charger, lid closed | agent locks, agent
        // blanks, block held, sleeps | block held, sleeps after idle display-off
        let rows: [(Int, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (1, true, true, true, false, false, false, true, false, true, false),
            (2, true, true, true, true, false, false, true, false, true, false),
            (3, true, true, false, false, false, false, true, false, true, false),
            (4, true, true, false, true, false, false, true, false, true, false),
            (5, true, false, true, false, false, false, true, false, true, false),
            (6, true, false, true, true, false, false, true, false, true, false),
            (7, true, false, false, false, false, false, true, false, false, false),
            (8, true, false, false, true, false, false, true, false, false, true),
            (9, false, true, true, false, false, false, true, false, true, false),
            (10, false, true, true, true, true, true, true, false, true, false),
            (11, false, true, false, false, false, false, true, false, true, false),
            (12, false, true, false, true, true, true, true, false, true, false),
            (13, false, false, true, false, false, false, true, false, true, false),
            (14, false, false, true, true, true, true, true, false, true, false),
            (15, false, false, false, false, false, false, false, false, false, false),
            (16, false, false, false, true, true, true, false, true, false, false),
        ]
        expect(rows.count == 16 && Set(rows.map { $0.0 }).count == 16, "every truth-table row has a test")
        for (row, monitor, coffee, charger, closed, locks, blanks, held, sleeps, heldIdle, sleepsIdle) in rows {
            var engine = PolicyEngine()
            var input = sample(ac: charger, coffee: coffee, disabled: true, locked: false, external: monitor)
            input.displaysAsleep = false
            input.idleSeconds = 0
            var actions = step(&engine, &input, 0)
            input.idleSeconds = 170
            actions += step(&engine, &input, 1)
            if closed {
                input.lidClosed = true
                actions += step(&engine, &input, 2)
                if actions.contains(.lock) { input.screenLocked = true }
                actions += step(&engine, &input, 3)
                actions += step(&engine, &input, 4)
            } else {
                actions += step(&engine, &input, 2)
            }
            expect(actions.contains(.lock) == locks, "row \(row): lock")
            expect(actions.contains(.displaySleep) == blanks, "row \(row): Mac screen")
            expect(input.sleepDisabled == held, "row \(row): Mac state")
            expect(actions.contains(.sleep) == sleeps, "row \(row): sleep")
            if row == 16 { continue } // Asleep: nothing runs until a wake.

            macOSIdleDisplayOff(&input)
            actions = step(&engine, &input, 200)
            actions += step(&engine, &input, 201)
            expect(input.sleepDisabled == heldIdle, "row \(row): Mac state after the configured window")
            expect(actions.contains(.sleep) == sleepsIdle, "row \(row): sleep after the configured window")
            expect(!actions.contains(.lock) && !actions.contains(.displaySleep), "row \(row): macOS, not the agent, locks and blanks after its window")
        }
    }

    static func rowEightTrigger() {
        // Docked, Coffee off, on battery, lid closed, in use.
        func row8() -> (PolicyEngine, PolicySample) {
            var engine = PolicyEngine()
            var input = sample(closed: true, disabled: true, locked: false, external: true)
            input.displaysAsleep = false
            input.idleSeconds = 0
            _ = step(&engine, &input, 0)
            return (engine, input)
        }

        var (engine, input) = row8()
        input.idleSeconds = 600
        expectUndisturbed(step(&engine, &input, 600), "row 8: reading with the monitor on never sleeps")
        expect(input.sleepDisabled == true, "row 8: the block holds while the monitor is on")
        macOSIdleDisplayOff(&input)
        var actions = step(&engine, &input, 601)
        expect(actions.contains(.setSleepDisabled(false)) && !actions.contains(.sleep), "row 8: idle display-off releases the block before sleeping")
        var fresh = input
        fresh.displaysAsleep = false
        expect(engine.awakeRequired(fresh) == true, "row 8: a fresh reading with the monitor back on aborts a stale release")
        fresh = input
        fresh.idleSeconds = 0
        expect(engine.awakeRequired(fresh) == true, "row 8: a fresh reading after input aborts a stale sleep")
        actions = step(&engine, &input, 602)
        expect(actions.contains(.sleep), "row 8: sleeps once macOS's idle display sleep turns the monitor off")
        engine.willSleep()
        engine.didWake()
        input.idleSeconds = 3600
        actions = step(&engine, &input, 603)
        expect(!actions.contains(.setSleepDisabled(true)) && actions.contains(.sleep), "row 8: a dark wake with the monitor still off goes back to sleep")
        input.displaysAsleep = false
        input.idleSeconds = 0
        actions = step(&engine, &input, 604)
        expect(actions.contains(.setSleepDisabled(true)) && !actions.contains(.sleep), "row 8: a user wake turns the monitor on and restores the block")

        (engine, input) = row8()
        input.screenLocked = true // Locked by hand.
        input.displaysAsleep = true // Escape on the lock screen.
        input.idleSeconds = 1
        actions = step(&engine, &input, 1)
        for idle in [30.0, 180, 3600, 86400] {
            input.idleSeconds = idle
            actions += step(&engine, &input, idle)
        }
        expect(!actions.contains(.setSleepDisabled(false)) && !actions.contains(.sleep), "row 8: Escape on the lock screen keeps apps running however long the displays stay off")
        input.displaysAsleep = false
        input.idleSeconds = 0
        _ = step(&engine, &input, 86401)
        macOSIdleDisplayOff(&input)
        actions = step(&engine, &input, 86581)
        actions += step(&engine, &input, 86582)
        expect(actions.contains(.sleep), "row 8: after an Escape, the next idle display-off still sleeps")

        (engine, input) = row8()
        macOSIdleDisplayOff(&input)
        _ = step(&engine, &input, 180)
        input.idleSeconds = 0 // A key press while the monitor wakes.
        actions = step(&engine, &input, 181)
        expect(actions.contains(.setSleepDisabled(true)) && !actions.contains(.sleep), "row 8: input before the sleep restores the block")

        // The lock-screen flag can lag the display-off. Docked, the agent never
        // locks; an immediate password makes the sleep itself lock.
        for immediate in [true, false] {
            (engine, input) = row8()
            macOSIdleDisplayOff(&input)
            input.screenLocked = false
            input.sleepLockImmediate = immediate
            actions = step(&engine, &input, 180)
            actions += step(&engine, &input, 181)
            expect(!actions.contains(.lock), "row 8: the agent never locks while a monitor is connected")
            expect(actions.contains(.sleep) == immediate && input.sleepDisabled == !immediate, "row 8: an unverified lock sleeps only with an immediate password")
        }

        (engine, input) = row8()
        macOSIdleDisplayOff(&input)
        input.idleSeconds = nil
        actions = step(&engine, &input, 180)
        expect(!actions.contains(.setSleepDisabled(false)) && !actions.contains(.sleep), "row 8: an unknown input reading never sleeps")

        // Row 7: the block holds until the idle display-off, so closing the
        // lid while the monitor is on never lets macOS sleep on lid close.
        engine = PolicyEngine()
        input = sample(disabled: true, locked: false, external: true)
        input.displaysAsleep = false
        input.idleSeconds = 0
        _ = step(&engine, &input, 0)
        input.lidClosed = true
        actions = step(&engine, &input, 1)
        expectUndisturbed(actions, "row 7 to 8: closing the lid with the monitor on keeps the session")
        expect(input.sleepDisabled == true, "row 7 to 8: the block holds through the lid close")
        input.lidClosed = false
        _ = step(&engine, &input, 2)
        macOSIdleDisplayOff(&input)
        actions = step(&engine, &input, 182)
        expect(input.sleepDisabled == false && !actions.contains(.sleep), "row 7: idle display-off releases the block and leaves the sleep to macOS")
        input.lidClosed = true
        expect(step(&engine, &input, 183).contains(.sleep), "row 7 to 8: closing the lid after the release sleeps")

        // A monitor plugged in while the displays are off from idle is woken,
        // which needs the block, so it never counts as an idle display-off.
        engine = PolicyEngine()
        input = sample(disabled: true, locked: false)
        input.displaysAsleep = false
        input.idleSeconds = 0
        _ = step(&engine, &input, 0)
        expect(input.sleepDisabled == false, "row 15: released")
        macOSIdleDisplayOff(&input)
        _ = step(&engine, &input, 180)
        input.externalDisplayConnected = true
        actions = step(&engine, &input, 181)
        expect(actions.contains(.setSleepDisabled(true)) && !actions.contains(.sleep), "row 15 to 7: plugging in a monitor restores the block for its wake")
        expect(canWakeAttachedDisplays([5], currentIDs: [5], sample: input), "row 15 to 7: the attachment wake can run")
    }

    static func powerSettle() {
        var settle = PowerSettle()
        expect(settle.update(false, now: 0) == true, "startup on battery counts as the charger until 30 s pass")
        expect(settle.update(false, now: 29.9) == true, "29.9 s on battery still counts as the charger")
        expect(settle.update(false, now: 30) == false, "30 s on battery counts as battery")
        expect(settle.update(true, now: 31) == true, "the charger returning counts at once")
        expect(settle.update(false, now: 32) == true, "a new drop starts a new 30 s count")
        expect(settle.update(nil, now: 61) == nil, "an unknown reading stays unknown")
        expect(settle.update(false, now: 62) == true, "an unknown reading breaks the battery run")
        expect(settle.update(false, now: 92) == false, "a fresh 30 s run counts as battery")

        // The hub's flicker: about one second on battery every 11 seconds.
        let flicker: (Double) -> Bool = { Int($0) % 11 != 5 }
        func run(_ engine: inout PolicyEngine, _ settle: inout PowerSettle, _ input: inout PolicySample,
                 _ reading: (Double) -> Bool, _ times: ClosedRange<Int>) -> [PolicyAction] {
            var actions: [PolicyAction] = []
            for t in times {
                input.externalPower = settle.update(reading(Double(t)), now: Double(t))
                actions += step(&engine, &input, Double(t))
            }
            return actions
        }
        var engine = PolicyEngine()
        settle = PowerSettle()
        var input = sample(disabled: true, locked: false)
        var actions = run(&engine, &settle, &input, { _ in true }, 0...5)
        actions += run(&engine, &settle, &input, flicker, 6...600)
        expect(!actions.contains(.setSleepDisabled(false)), "row 13: the hub flicker never flips the block")

        // Row 14 on the hub: a flicker never sleeps; 30 s unplugged is row 16.
        engine = PolicyEngine()
        settle = PowerSettle()
        input = sample(disabled: true, locked: false)
        _ = run(&engine, &settle, &input, { _ in true }, 0...1)
        input.lidClosed = true
        actions = run(&engine, &settle, &input, { _ in true }, 2...2)
        expect(actions.contains(.lock), "row 14: lid close locks")
        input.screenLocked = true
        actions = run(&engine, &settle, &input, flicker, 3...600)
        expect(!actions.contains(.setSleepDisabled(false)) && !actions.contains(.sleep), "row 14: the hub flicker never sleeps a closed Mac")
        actions = run(&engine, &settle, &input, { _ in false }, 601...630)
        expect(!actions.contains(.setSleepDisabled(false)) && !actions.contains(.sleep), "row 14: 29 s unplugged still counts as the charger")
        actions = run(&engine, &settle, &input, { _ in false }, 631...640)
        expect(actions.contains(.setSleepDisabled(false)) && actions.contains(.sleep), "row 14 to 16: 30 s unplugged sleeps")

        // Row 6 on the hub with the monitor already off from idle: a flicker
        // never sleeps; 30 s unplugged is row 8, whose window has passed.
        engine = PolicyEngine()
        settle = PowerSettle()
        input = sample(closed: true, disabled: true, locked: false, external: true)
        input.displaysAsleep = false
        input.idleSeconds = 0
        _ = run(&engine, &settle, &input, { _ in true }, 0...5)
        macOSIdleDisplayOff(&input)
        actions = run(&engine, &settle, &input, flicker, 6...600)
        expect(!actions.contains(.setSleepDisabled(false)) && !actions.contains(.sleep), "row 6: the hub flicker never sleeps a docked Mac")
        actions = run(&engine, &settle, &input, { _ in false }, 601...630)
        expect(!actions.contains(.setSleepDisabled(false)) && !actions.contains(.sleep), "row 6: 29 s unplugged still counts as the charger")
        actions = run(&engine, &settle, &input, { _ in false }, 631...640)
        expect(actions.contains(.setSleepDisabled(false)) && actions.contains(.sleep), "row 6 to 8: 30 s unplugged with the monitor off from idle sleeps")
    }

    static func main() throws {
        for ac in [false, true] {
            for coffee in [false, true] {
                for closed in [false, true] {
                    for disabled in [false, true] {
                        var engine = PolicyEngine()
                        let input = sample(ac: ac, coffee: coffee, closed: closed, disabled: disabled)
                        let actions = engine.plan(input, now: 0)
                        let awake = coffee || ac
                        expect(input.awakeRequired == awake, "awake truth table")
                        expect(actions.contains(.setSleepDisabled(awake)) == (awake != disabled), "global-bit reconciliation")
                        expect(actions.contains(.sleep) == (!awake && closed && !disabled), "startup undocked Coffee-off closed-lid sleep happens only on battery")
                        expect(!actions.contains(.lock) && !actions.contains(.displaySleep), "already-locked startup never adds lock or display-off")
                    }
                }
            }
        }

        let states = [false, true].flatMap { ac in
            [false, true].flatMap { coffee in
                [false, true].map { closed in sample(ac: ac, coffee: coffee, closed: closed, disabled: coffee || ac) }
            }
        }
        for old in states {
            for next in states {
                var engine = PolicyEngine()
                _ = engine.plan(old, now: 0)
                engine.willSleep()
                var input = next
                input.sleepDisabled = old.sleepDisabled
                let actions = engine.plan(input, now: 10)
                let awake = next.awakeRequired!
                let closing = old.lidClosed == false && next.lidClosed == true
                let changed = old.externalPower != next.externalPower || old.caffeinate != next.caffeinate
                let sleepEvent = next.lidClosed == true && !awake && (closing || changed)
                expect(actions.contains(.setSleepDisabled(awake)) == (old.sleepDisabled != awake), "transition global-bit reconciliation")
                expect(actions.contains(.sleep) == (sleepEvent && old.sleepDisabled == false), "transition sleep ordering")
                expect(actions.contains(.displaySleep) == closing, "only an observed lid-close edge requests display-off")
                if sleepEvent && old.sleepDisabled == true {
                    input.sleepDisabled = false
                    expect(engine.plan(input, now: 11).contains(.sleep), "verify global inhibition release before sleep")
                }
            }
        }

        // Regression: docking, video, reading, or a false HID-idle reading must
        // never lock or blank an awake machine, including closed-lid startup.
        let awakeStates = [(true, false), (true, true), (false, true)]
        for (ac, coffee) in awakeStates {
            for closed in [false, true] {
                var engine = PolicyEngine()
                var input = sample(ac: ac, coffee: coffee, closed: closed, disabled: true, locked: false, external: true)
                for idle in [0.0, 179, 180, 1000, 86400] {
                    input.idleSeconds = idle
                    expectUndisturbed(engine.plan(input, now: idle), "idle diagnostic must never trigger lock/display-off")
                }
                engine.didWake()
                expectUndisturbed(engine.plan(input, now: 86401), "wake with an already-closed lid is a baseline, not a closure")
            }
        }
        for old in awakeStates {
            for next in awakeStates {
                var engine = PolicyEngine()
                _ = engine.plan(sample(ac: old.0, coffee: old.1, closed: true, disabled: true, locked: false, external: true), now: 0)
                let input = sample(ac: next.0, coffee: next.1, closed: true, disabled: true, locked: false, external: true)
                expectUndisturbed(engine.plan(input, now: 1), "AC/Coffee changes while already closed must not lock or blank docked use")
            }
        }

        var engine = PolicyEngine()
        var input = sample(ac: true, coffee: true, disabled: true, locked: false)
        _ = engine.plan(input, now: 0)
        input.lidClosed = true
        expect(engine.plan(input, now: 1).contains(.lock), "actual open-to-closed edge locks")
        input.screenLocked = true
        let verified = engine.plan(input, now: 2)
        expect(verified.contains(.displaySleep), "actual closure blanks displays only after verified lock")
        expect(!verified.contains(.sleep), "undocked Coffee display-off preserves running apps")
        input.displaysAsleep = true
        _ = engine.plan(input, now: 3)
        input.displaysAsleep = false
        input.screenLocked = false
        input.caffeinate = true
        expectUndisturbed(engine.plan(input, now: 40), "unlock and Coffee change do not re-arm a completed closure")
        input.externalPower = false
        expectUndisturbed(engine.plan(input, now: 41), "unplug while Coffee remains active does not lock docked use")
        input.caffeinate = false
        expect(engine.plan(input, now: 42).contains(.lock), "battery sleep transition re-locks for security")
        input.screenLocked = true
        expect(engine.plan(input, now: 43).contains(.setSleepDisabled(false)), "battery transition releases inhibition after verified lock")
        input.sleepDisabled = false
        expect(engine.plan(input, now: 44).contains(.sleep), "battery without Coffee explicitly sleeps despite idle blockers")
        engine.willSleep()
        expect(!engine.plan(input, now: 80).contains(.sleep), "sleep notification stops retries")

        engine = PolicyEngine()
        input = sample(closed: true, disabled: true, locked: false)
        expect(engine.plan(input, now: 0).contains(.lock), "startup battery closed/no Coffee locks before sleep")
        input.sleepLockImmediate = true
        _ = engine.plan(input, now: 1)
        _ = engine.plan(input, now: 2)
        expect(engine.plan(input, now: 3).contains(.setSleepDisabled(false)), "secure immediate-lock sleep fallback after three native attempts")

        // Unknown recovery cannot invent an open-to-closed edge.
        engine = PolicyEngine()
        input = sample(ac: true, coffee: true, closed: true, disabled: true, locked: false)
        input.lidClosed = nil
        _ = engine.plan(input, now: 0)
        input.lidClosed = true
        expectUndisturbed(engine.plan(input, now: 1), "unknown-to-closed recovery has no observed open edge")
        engine = PolicyEngine()
        input.lidClosed = false
        _ = engine.plan(input, now: 0)
        input.lidClosed = nil
        _ = engine.plan(input, now: 1)
        input.lidClosed = true
        expect(engine.plan(input, now: 2).contains(.lock), "last observed open-to-closed edge still works across missing readings")

        engine = PolicyEngine()
        input = sample(ac: true, disabled: true, locked: false)
        _ = engine.plan(input, now: -1)
        input.lidClosed = true
        var locks = 0
        for tick in 0...40 { locks += engine.plan(input, now: Double(tick)).filter { $0 == .lock }.count }
        expect(locks == 5, "failed closure locks continue with capped 1/2/5/30 backoff")
        input.lidClosed = false
        _ = engine.plan(input, now: 41)
        input.lidClosed = true
        expect(engine.plan(input, now: 42).contains(.lock), "a real new closure resets lock backoff")

        engine = PolicyEngine()
        input = sample(ac: true, coffee: true, disabled: true)
        _ = engine.plan(input, now: -1)
        input.lidClosed = true
        var displays = 0
        for tick in 0...40 {
            let actions = engine.plan(input, now: Double(tick))
            displays += actions.filter { $0 == .displaySleep }.count
            expect(!actions.contains(.sleep), "display retries never system-sleep AC work")
        }
        expect(displays == 5, "display off requires asleep observation and keeps capped retries")
        input.lidClosed = false
        expect(!engine.plan(input, now: 41).contains(.displaySleep), "opening lid cancels pending display off")
        expect(!canDisplaySleep(sample: input), "fresh open lid rejects stale display-off action")

        engine = PolicyEngine()
        input = sample(ac: true, disabled: false)
        var writes = 0
        for tick in 0...120 { writes += engine.plan(input, now: Double(tick)).filter { $0 == .setSleepDisabled(true) }.count }
        expect(writes == 7, "global writes keep capped backoff")
        input.sleepDisabled = true
        _ = engine.plan(input, now: 121)
        input.sleepDisabled = false
        expect(engine.plan(input, now: 121.1).contains(.setSleepDisabled(true)), "repair new drift immediately after a confirmed match")
        engine = PolicyEngine()
        input = sample(closed: true)
        var sleeps = 0
        for tick in 0...120 { sleeps += engine.plan(input, now: Double(tick)).filter { $0 == .sleep }.count }
        expect(sleeps == 6, "unconfirmed battery sleep keeps capped retries")
        input.externalPower = nil
        let unknown = engine.plan(input, now: 121)
        expect(!unknown.contains(.sleep) && !unknown.contains(.setSleepDisabled(false)), "unknown power never forces sleep")

        // A usable external monitor is itself an awake requirement, including
        // hubs without charging. Docked mode takes priority over Coffee and
        // preserves a usable clamshell session for either Coffee setting.
        for ac in [false, true] {
            for coffee in [false, true] {
                for closed in [false, true] {
                    for disabled in [false, true] {
                        engine = PolicyEngine()
                        input = sample(ac: ac, coffee: coffee, closed: closed,
                                       disabled: disabled, locked: false, external: true)
                        let startup = engine.plan(input, now: 0)
                        expect(input.awakeRequired == true, "external monitor requires awake on AC or battery")
                        expectUndisturbed(startup, "docked startup keeps the usable session unlocked and displays on")
                        expect(startup.contains(.setSleepDisabled(true)) == !disabled, "docked startup enforces global keep-awake")
                        input.sleepDisabled = true
                        input.lidClosed = false
                        _ = engine.plan(input, now: 1)
                        input.lidClosed = true
                        let dockedClose = engine.plan(input, now: 2)
                        expectUndisturbed(dockedClose, "docked clamshell use takes priority over both Coffee settings")
                        expect(!canRequestLock(sample: input), "fresh external display rejects a stale lock action even with Coffee on")
                        input.screenLocked = true
                        expect(!canDisplaySleep(sample: input), "fresh external display blocks a stale display-off action")
                    }
                }
            }
        }

        engine = PolicyEngine()
        input = sample(closed: true, disabled: true, locked: false, external: true)
        _ = engine.plan(input, now: 0)
        input.externalDisplayConnected = false
        let detached = engine.plan(input, now: 1)
        expect(detached.contains(.lock) && !detached.contains(.sleep), "detaching monitor on battery initiates secure closed-lid sleep")
        input.screenLocked = true
        expect(engine.plan(input, now: 2).contains(.setSleepDisabled(false)), "detach releases inhibition after lock verification")
        input.sleepDisabled = false
        expect(engine.plan(input, now: 3).contains(.sleep), "detached battery/no-Coffee Mac sleeps")

        for (ac, coffee) in [(true, false), (true, true), (false, true)] {
            engine = PolicyEngine()
            input = sample(ac: ac, coffee: coffee, closed: true, disabled: true, locked: false, external: true)
            expectUndisturbed(engine.plan(input, now: 0), "docked closed startup stays usable before detach")
            input.externalDisplayConnected = nil
            expectUndisturbed(engine.plan(input, now: 1), "unknown enumeration does not prematurely end docked mode")
            input.externalDisplayConnected = false
            let undocked = engine.plan(input, now: 2)
            expect(undocked.contains(.lock), "confirmed closed-lid detach restores undocked lock on AC or Coffee")
            expect(!undocked.contains(.setSleepDisabled(false)) && !undocked.contains(.sleep), "undock locks before changing power or requesting sleep")
            input.screenLocked = true
            let detachedLocked = engine.plan(input, now: 3)
            expect(detachedLocked.contains(.displaySleep), "confirmed closed-lid detach blanks displays after verified lock")
            expect(!detachedLocked.contains(.sleep), "detach observes global-bit release before system sleep")
            expect(!detachedLocked.contains(.setSleepDisabled(false)), "detached session on Coffee or a charger stays awake (rows 10, 12, 14)")
            expect(!engine.plan(input, now: 40).contains(.sleep), "detached session on Coffee or a charger never sleeps")
        }

        engine = PolicyEngine()
        input = sample(ac: true, disabled: true, locked: false)
        _ = engine.plan(input, now: 0)
        input.lidClosed = true
        expect(engine.plan(input, now: 1).contains(.lock), "undocked closure can queue lock")
        input.externalDisplayConnected = true
        expectUndisturbed(engine.plan(input, now: 2), "monitor attachment cancels a pending lid lock")
        input.screenLocked = true
        expectUndisturbed(engine.plan(input, now: 40), "monitor attachment cancels a pending display-off retry")

        engine = PolicyEngine()
        input = sample(closed: true, disabled: true, locked: false)
        expect(engine.plan(input, now: 0).contains(.lock), "undocked battery can queue sleep security")
        input.externalDisplayConnected = true
        let attached = engine.plan(input, now: 1)
        expectUndisturbed(attached, "monitor attachment cancels pending battery sleep")
        expect(!attached.contains(.setSleepDisabled(false)), "monitor attachment never clears the awake requirement")

        engine = PolicyEngine()
        input = sample(closed: true, disabled: true, locked: false, external: nil)
        expect(input.awakeRequired == nil, "unknown display attachment cannot be treated as undocked")
        let unknownDisplay = engine.plan(input, now: 0)
        expectUndisturbed(unknownDisplay, "unknown display reading never locks, blanks, or sleeps")
        expect(!unknownDisplay.contains(.setSleepDisabled(false)), "unknown display reading holds the global inhibition")
        input.screenLocked = true
        expect(!canRequestLock(sample: input) && !canDisplaySleep(sample: input), "fresh unknown display reading rejects disruptive actions")
        input.externalDisplayConnected = true
        expectUndisturbed(engine.plan(input, now: 1), "positive display recovery preserves the docked session")
        input.externalDisplayConnected = nil
        input.externalPower = true
        input.sleepDisabled = false
        expect(engine.plan(input, now: 2).contains(.setSleepDisabled(true)), "positive AC evidence still prevents sleep during unknown display enumeration")

        // Latest lid rule: docked wins over Coffee; undocked Coffee-off sleeps
        // even on charger-only AC. All actions below remain pure simulations.
        for ac in [false, true] {
            for coffee in [false, true] {
                for external in [false, true] {
                    engine = PolicyEngine()
                    input = sample(ac: ac, coffee: coffee, disabled: true, locked: false, external: external)
                    _ = engine.plan(input, now: 0)
                    input.lidClosed = true
                    let closed = engine.plan(input, now: 1)
                    if external {
                        expectUndisturbed(closed, "docked close never locks, blanks, or sleeps for either Coffee setting")
                        expect(!closed.contains(.setSleepDisabled(false)), "docked close never clears keep-awake")
                        expect(!canRequestLock(sample: input), "fresh docked state blocks queued lock regardless of Coffee")
                    } else {
                        expect(closed.contains(.lock), "undocked close always secures the session")
                        expect(!closed.contains(.sleep) && !closed.contains(.setSleepDisabled(false)), "undocked close verifies locking before power changes")
                        input.screenLocked = true
                        let secured = engine.plan(input, now: 2)
                        expect(secured.contains(.displaySleep), "undocked closure blanks displays after lock verification")
                        if coffee || ac {
                            expect(input.awakeRequired == true && !secured.contains(.sleep) && !secured.contains(.setSleepDisabled(false)), "undocked Coffee-on or charger keeps apps running after locking")
                        } else {
                            expect(input.awakeRequired == false && secured.contains(.setSleepDisabled(false)), "undocked Coffee-off on battery releases keep-awake")
                            input.sleepDisabled = false
                            expect(engine.plan(input, now: 3).contains(.sleep), "undocked Coffee-off on battery closes into system sleep")
                        }
                    }
                }
            }
        }

        for ac in [false, true] {
            for coffee in [false, true] {
                engine = PolicyEngine()
                input = sample(ac: ac, coffee: coffee, disabled: true, locked: false)
                _ = engine.plan(input, now: 0)
                input.lidClosed = true
                expect(engine.plan(input, now: 1).contains(.lock), "undocked close can queue security action")
                input.externalDisplayConnected = true
                expectUndisturbed(engine.plan(input, now: 2), "dock attach cancels pending closure even with Coffee on")
                expect(!canRequestLock(sample: input), "fresh monitor attachment cancels stale undocked lock")
                input.screenLocked = true
                expectUndisturbed(engine.plan(input, now: 40), "docked state cancels pending blank and sleep retries")
            }
        }

        for ac in [false, true] {
            for coffee in [false, true] {
                engine = PolicyEngine()
                input = sample(ac: ac, coffee: coffee, disabled: true, locked: false, external: nil)
                expectUndisturbed(engine.plan(input, now: 0), "unknown docking state never disrupts an open-lid session")
                input.lidClosed = true
                expectUndisturbed(engine.plan(input, now: 1), "unknown docking state never locks or sleeps a closure")
                expect(!canRequestLock(sample: input), "unknown external reading denies fresh lock even with Coffee on")
                input.screenLocked = true
                expect(!canDisplaySleep(sample: input), "unknown external reading denies fresh display-off")
                input.externalDisplayConnected = true
                expectUndisturbed(engine.plan(input, now: 2), "confirmed dock recovery preserves the usable session")
            }
        }

        engine = PolicyEngine()
        input = sample(ac: true, coffee: true, closed: true, disabled: true, locked: false)
        input.idleSeconds = 86400
        expectUndisturbed(engine.plan(input, now: 0), "undocked Coffee-on restart while already closed does not invent a closure")
        engine.didWake()
        expectUndisturbed(engine.plan(input, now: 1), "undocked Coffee-on wake does not autonomously relock")

        var attachments = DisplayAttachmentTracker()
        expect(attachments.newlyAttached(nil).isEmpty, "unknown initial display reading is not an attachment")
        expect(attachments.newlyAttached([10]).isEmpty, "first known connected monitor is baseline, so restart never wakes it")
        expect(attachments.newlyAttached([10]).isEmpty, "same attached monitor never creates a heartbeat wake")
        expect(attachments.newlyAttached(nil).isEmpty, "unknown display reading retains the last baseline")
        expect(attachments.newlyAttached([10]).isEmpty, "recovery from unknown does not fake a new attachment")
        expect(attachments.newlyAttached([10, 20, 20]) == [20], "only a newly added external ID requests wake once")
        expect(attachments.newlyAttached([20, 10]).isEmpty, "ID ordering never triggers a wake")
        expect(attachments.newlyAttached([20]).isEmpty, "detaching a monitor never requests wake")
        expect(attachments.newlyAttached([10, 20]) == [10], "a physically reattached ID requests one new wake")

        attachments = DisplayAttachmentTracker()
        expect(attachments.newlyAttached([]).isEmpty, "undocked startup establishes an empty baseline")
        let added = attachments.newlyAttached([30])
        expect(added == [30], "monitor attached after undocked startup requests wake")
        input = sample(closed: true, disabled: false, locked: true, external: true)
        expect(!canWakeAttachedDisplays(added, currentIDs: [30], sample: input), "wake waits for verified global keep-awake even with lid closed")
        input.sleepDisabled = true
        expect(canWakeAttachedDisplays(added, currentIDs: [30], sample: input), "verified global keep-awake permits attachment wake")
        expect(!canWakeAttachedDisplays(added, currentIDs: [], sample: input), "freshly detached ID aborts a stale wake request")
        expect(!canWakeAttachedDisplays(added, currentIDs: nil, sample: input), "unknown fresh enumeration aborts a wake request")
        input.displaysAsleep = true
        expect(attachments.newlyAttached([30]).isEmpty, "Esc display-off while still online is never a new attachment")
        input.displaysAsleep = false
        input.lidClosed = false
        expect(attachments.newlyAttached([30]).isEmpty, "wake or lid-mode change with identical online IDs never wakes again")

        var pendingWake = PendingAttachmentWake()
        pendingWake.enqueue([30], now: 0)
        input = sample(closed: true, disabled: false, external: true)
        let waiting = pendingWake.candidates(currentIDs: nil, now: 1)
        expect(waiting == [30] && !canWakeAttachedDisplays(waiting, currentIDs: nil, sample: input), "unknown hotplug enumeration retains request without attempting wake")
        let notYetAwake = pendingWake.candidates(currentIDs: [30], now: 2)
        expect(notYetAwake == [30] && !canWakeAttachedDisplays(notYetAwake, currentIDs: [30], sample: input), "pending wake survives a temporarily unready global bit")
        input.sleepDisabled = true
        let ready = pendingWake.candidates(currentIDs: [30], now: 3)
        expect(canWakeAttachedDisplays(ready, currentIDs: [30], sample: input), "pending request becomes ready after asynchronous keep-awake succeeds")
        pendingWake.attempted(ready)
        expect(pendingWake.candidates(currentIDs: [30], now: 4).isEmpty, "one activity call consumes pending request even if the API failed")

        pendingWake.enqueue([40], now: 10)
        expect(pendingWake.candidates(currentIDs: [40], now: 15).isEmpty, "pending wake expires after five seconds without a call")
        pendingWake.enqueue([50], now: 20)
        expect(pendingWake.candidates(currentIDs: [], now: 21).isEmpty, "confirmed detach cancels pending wake")
        pendingWake.enqueue([60], now: 30)
        pendingWake.cancel() // NSWorkspace.screensDidSleepNotification / Esc.
        expect(pendingWake.candidates(currentIDs: [60], now: 31).isEmpty, "native display sleep cancels pending wake before its first call")
        pendingWake.enqueue([70], now: 40)
        pendingWake.cancel() // NSWorkspace.willSleepNotification.
        expect(pendingWake.candidates(currentIDs: [70], now: 41).isEmpty, "system sleep cancels pending wake")
        pendingWake.enqueue([80], now: 50)
        pendingWake.enqueue([90], now: 54)
        expect(pendingWake.candidates(currentIDs: [80, 90], now: 55) == [90], "a second attachment never extends an old attachment deadline")

        expect(!isUsableExternalDisplay(builtIn: true, vendor: 1715, model: 10019, serial: 0), "built-in panel is not docked external output")
        expect(isUsableExternalDisplay(builtIn: false, vendor: 1715, model: 10019, serial: 0), "physical ASUS monitor remains usable")
        expect(!isUsableExternalDisplay(builtIn: false, vendor: 0x756e6b6e, model: 0x76697274, serial: 0), "exact unplug fallback placeholder is not usable external output")
        expect(isUsableExternalDisplay(builtIn: false, vendor: 0, model: 0, serial: 0), "generic or DisplayLink output is not broadly excluded")
        expect(isUsableExternalDisplay(builtIn: false, vendor: 0x756e6b6f, model: 0x76697274, serial: 0), "nearby vendor signature remains usable")
        expect(isUsableExternalDisplay(builtIn: false, vendor: 0x756e6b6e, model: 0x76697275, serial: 0), "nearby model signature remains usable")
        expect(isUsableExternalDisplay(builtIn: false, vendor: 0x756e6b6e, model: 0x76697274, serial: 1), "nonzero serial is outside the exact fallback exclusion")

        let unplugDisplays: [(CGDirectDisplayID, UInt32, UInt32, UInt32)] = [(8, 0x756e6b6e, 0x76697274, 0)]
        let usableAfterUnplug = unplugDisplays.filter {
            isUsableExternalDisplay(builtIn: false, vendor: $0.1, model: $0.2, serial: $0.3)
        }.map { $0.0 }
        expect(usableAfterUnplug.isEmpty, "phantom CGID 8 does not count as a monitor after unplug")
        attachments = DisplayAttachmentTracker()
        _ = attachments.newlyAttached([3]) // Real ASUS before unplug.
        expect(attachments.newlyAttached(usableAfterUnplug).isEmpty, "replacement fallback never becomes an attachment-wake candidate")
        for (ac, coffee) in [(true, false), (false, true), (false, false)] {
            engine = PolicyEngine()
            input = sample(ac: ac, coffee: coffee, closed: true, disabled: true, locked: false, external: true)
            _ = engine.plan(input, now: 0)
            input.externalDisplayConnected = !usableAfterUnplug.isEmpty
            let unplugged = engine.plan(input, now: 1)
            expect(unplugged.contains(.lock), "real-to-fallback replacement is a confirmed undocked security boundary")
            input.screenLocked = true
            let secured = engine.plan(input, now: 2)
            if coffee || ac {
                expect(input.awakeRequired == true && secured.contains(.displaySleep), "real-to-fallback with Coffee or a charger locks and blanks while staying awake")
                expect(!secured.contains(.setSleepDisabled(false)), "real-to-fallback preserves explicit awake requirements")
            } else {
                expect(input.awakeRequired == false && secured.contains(.setSleepDisabled(false)), "phantom alone never keeps a closed Coffee-off Mac awake on battery")
                input.sleepDisabled = false
                expect(engine.plan(input, now: 3).contains(.sleep), "real-to-fallback without Coffee or a charger sleeps")
            }
        }

        try truthTable()
        rowEightTrigger()
        powerSettle()

        let config = try Configuration.parse([])
        expect(config.mode == "--status", "default invocation is read-only")
        print("Passed \(assertions) policy assertions; no power or lock actions executed.")
    }
}

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

    static func main() throws {
        for ac in [false, true] {
            for coffee in [false, true] {
                for closed in [false, true] {
                    for disabled in [false, true] {
                        var engine = PolicyEngine()
                        let input = sample(ac: ac, coffee: coffee, closed: closed, disabled: disabled)
                        let actions = engine.plan(input, now: 0)
                        let awake = coffee || (ac && !closed)
                        expect(input.awakeRequired == awake, "awake truth table")
                        expect(actions.contains(.setSleepDisabled(awake)) == (awake != disabled), "global-bit reconciliation")
                        expect(actions.contains(.sleep) == (!awake && closed && !disabled), "startup undocked Coffee-off closed-lid sleep includes charger-only AC")
                        expect(!actions.contains(.lock) && !actions.contains(.displaySleep), "already-locked startup never adds lock or display-off")
                    }
                }
            }
        }

        let states = [false, true].flatMap { ac in
            [false, true].flatMap { coffee in
                [false, true].map { closed in sample(ac: ac, coffee: coffee, closed: closed, disabled: coffee || (ac && !closed)) }
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
            if coffee {
                expect(!detachedLocked.contains(.setSleepDisabled(false)), "detached Coffee-on session stays awake")
            } else {
                expect(detachedLocked.contains(.setSleepDisabled(false)), "detached Coffee-off session releases sleep inhibition even on AC")
                input.sleepDisabled = false
                expect(engine.plan(input, now: 4).contains(.sleep), "detached Coffee-off session sleeps even on charger-only AC")
            }
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
                        if coffee {
                            expect(input.awakeRequired == true && !secured.contains(.sleep) && !secured.contains(.setSleepDisabled(false)), "undocked Coffee-on keeps apps running after locking on AC or battery")
                        } else {
                            expect(input.awakeRequired == false && secured.contains(.setSleepDisabled(false)), "undocked Coffee-off releases keep-awake even with a charger connected")
                            input.sleepDisabled = false
                            expect(engine.plan(input, now: 3).contains(.sleep), "undocked Coffee-off closes into system sleep on AC or battery")
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
            if coffee {
                expect(input.awakeRequired == true && secured.contains(.displaySleep), "real-to-fallback with Coffee on locks and blanks while staying awake")
                expect(!secured.contains(.setSleepDisabled(false)), "real-to-fallback preserves explicit awake requirements")
            } else {
                expect(input.awakeRequired == false && secured.contains(.setSleepDisabled(false)), "phantom alone never keeps a closed Coffee-off Mac awake, including charger-only AC")
                input.sleepDisabled = false
                expect(engine.plan(input, now: 3).contains(.sleep), "real-to-fallback without Coffee sleeps on AC or battery")
            }
        }

        let config = try Configuration.parse([])
        expect(config.mode == "--status", "default invocation is read-only")
        print("Passed \(assertions) policy assertions; no power or lock actions executed.")
    }
}

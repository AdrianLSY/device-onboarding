import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

// One owner for the global disablesleep bit. AlDente's sleep prevention must be
// off; it continues to own the independent charge limit. No state is reset on
// exit: launchd restarts us, and resetting here could suspend work on AC power.
struct PolicySample: Equatable {
    var externalPower: Bool?
    var lidClosed: Bool?
    var caffeinate: Bool?
    var sleepDisabled: Bool?
    var screenLocked: Bool?
    var idleSeconds: Double? = nil
    var sleepLockImmediate = false
    var displaysAsleep: Bool? = nil
    var externalDisplayConnected: Bool? = false

    // The truth table's Mac state while the screens are on. A monitor or
    // Coffee keeps the Mac awake, and so does a charger with the lid open or
    // closed (rows 13 and 14). Only undocked, Coffee off, on battery may sleep.
    // PolicyEngine.awakeRequired adds rows 7 and 8: docked on battery with
    // Coffee off sleeps once the monitor turns off, for any reason.
    var awakeRequired: Bool? {
        if externalDisplayConnected == true || caffeinate == true { return true }
        if externalPower == true { return true }
        if externalPower == false && caffeinate == false && externalDisplayConnected == false { return false }
        return nil
    }

    var known: Bool {
        externalPower != nil && lidClosed != nil && caffeinate != nil && sleepDisabled != nil && externalDisplayConnected != nil
    }
}

func canDisplaySleep(sample: PolicySample) -> Bool {
    sample.screenLocked == true && sample.lidClosed == true && sample.externalDisplayConnected == false
}

func canRequestLock(sample: PolicySample) -> Bool {
    sample.lidClosed == true && sample.externalDisplayConnected == false
}

// Compare online external IDs, not active/asleep status. Esc may turn a still-
// attached monitor off, and neither polling nor a reconfiguration callback may
// turn that into a new attachment or undo the user's display-off request.
struct DisplayAttachmentTracker {
    private var baseline: Set<CGDirectDisplayID>?

    mutating func newlyAttached(_ externalIDs: [CGDirectDisplayID]?) -> [CGDirectDisplayID] {
        guard let externalIDs else { return [] }
        let current = Set(externalIDs)
        defer { baseline = current }
        guard let previous = baseline else { return [] }
        return current.subtracting(previous).sorted()
    }
}

struct PendingAttachmentWake {
    private var deadlines: [CGDirectDisplayID: Double] = [:]
    var isEmpty: Bool { deadlines.isEmpty }

    mutating func enqueue(_ addedIDs: [CGDirectDisplayID], now: Double) {
        for id in addedIDs where deadlines[id] == nil { deadlines[id] = now + 5 }
    }

    mutating func candidates(currentIDs: [CGDirectDisplayID]?, now: Double) -> [CGDirectDisplayID] {
        deadlines = deadlines.filter { $0.value > now }
        if let currentIDs {
            let connected = Set(currentIDs)
            deadlines = deadlines.filter { connected.contains($0.key) }
        }
        return deadlines.keys.sorted()
    }

    mutating func attempted(_ ids: [CGDirectDisplayID]) {
        for id in ids { deadlines.removeValue(forKey: id) }
    }

    mutating func cancel() { deadlines.removeAll() }
}

func canWakeAttachedDisplays(_ addedIDs: [CGDirectDisplayID], currentIDs: [CGDirectDisplayID]?, sample: PolicySample) -> Bool {
    guard sample.externalDisplayConnected == true, sample.sleepDisabled == true,
          let currentIDs else { return false }
    return !Set(addedIDs).intersection(currentIDs).isEmpty
}

// The hub's charging input reads false for about a second every few seconds.
// Losing the charger counts only after 30 continuous seconds on battery;
// regaining it counts at once, because staying awake is the safe side. Time is
// awake uptime, so a sleep in between neither adds to nor resets the count.
// Startup has seen no battery yet, so it also waits the full 30 seconds.
struct PowerSettle {
    static let window = 30.0
    private var batterySince: Double?

    mutating func update(_ reading: Bool?, now: Double) -> Bool? {
        guard let reading else {
            // An unknown reading is not battery and breaks the run.
            batterySince = nil
            return nil
        }
        if reading {
            batterySince = nil
            return true
        }
        let since = batterySince ?? now
        batterySince = since
        return now - since < Self.window
    }
}

enum PolicyAction: Equatable {
    case lock
    case displaySleep
    case setSleepDisabled(Bool)
    case sleep
    case log(String)
}

// All transitions and retry limits are testable without locking or sleeping.
struct PolicyEngine {
    private var previous: PolicySample?
    private var closureLocked = false
    private var lockAttempts = 0
    private var nextLock = 0.0
    private var pendingSleep = false
    private var sleepAttempts = 0
    private var nextSleep = 0.0
    private var enforceAttempts = 0
    private var nextEnforce = 0.0
    private var unknownReported = false
    private var lockExhaustedReported = false
    private var pendingLidDisplaySleep = false
    private var displaySleepAttempts = 0
    private var nextDisplaySleep = 0.0
    // A display-off lasts from the first reading with every display off to
    // the first with any on. A wake keeps it: a dark wake leaves the displays
    // off, and a user wake brings input and turns them on.
    private var displayOff = false
    // False once input arrives during this display-off, or a monitor is
    // plugged in during it (its wake needs the sleep block).
    private var displayOffCounts = false
    private var lastIdleSeconds: Double?
    private var previousDockedScreenOff = false

    // HID idle time only goes down when keyboard or mouse input arrives.
    private func inputSince(_ last: Double?, _ idle: Double?) -> Bool {
        guard let last, let idle else { return false }
        return idle + 0.1 < last
    }

    private mutating func trackDisplayOff(_ sample: PolicySample) {
        switch sample.displaysAsleep {
        case false?:
            displayOff = false
            displayOffCounts = false
        case true?:
            if !displayOff {
                // Input before this reading is what turned the screen off
                // (Escape, a hot corner); it does not count against it.
                displayOff = true
                displayOffCounts = true
            } else if inputSince(lastIdleSeconds, sample.idleSeconds) {
                displayOffCounts = false
            }
        case nil: break
        }
        if sample.externalDisplayConnected == true && previous?.externalDisplayConnected == false && displayOff {
            displayOffCounts = false
        }
        if let idle = sample.idleSeconds { lastIdleSeconds = idle }
    }

    // Rows 7 and 8: docked, Coffee off, on battery. The Mac stays awake while
    // the monitor is on and may sleep once every display is off, whatever
    // turned it off: macOS's idle display sleep, Escape on the lock screen, a
    // hot corner or `pmset displaysleepnow`. Input after the screen went off
    // means the user is back, so a key press waking a closed Mac keeps it
    // awake before the monitor reports itself on. No inactivity is timed
    // here: the screen-off alone is the trigger.
    func dockedScreenOff(_ sample: PolicySample) -> Bool {
        displayOffCounts && sample.idleSeconds != nil && !inputSince(lastIdleSeconds, sample.idleSeconds)
            && sample.externalDisplayConnected == true && sample.caffeinate == false
            && sample.externalPower == false && sample.displaysAsleep == true
    }

    func awakeRequired(_ sample: PolicySample) -> Bool? {
        dockedScreenOff(sample) ? false : sample.awakeRequired
    }

    private mutating func finishDisplaySleep() {
        pendingLidDisplaySleep = false
        displaySleepAttempts = 0
    }

    mutating func cancelDisplaySleep() { pendingLidDisplaySleep = false }

    private mutating func displaySleepAction(_ sample: PolicySample, now: Double) -> PolicyAction? {
        if sample.displaysAsleep == true {
            // pmset's exit status does not prove the display went off. Only
            // this independent CoreGraphics observation completes a one-shot.
            finishDisplaySleep()
            return nil
        }
        guard pendingLidDisplaySleep, canDisplaySleep(sample: sample), now >= nextDisplaySleep else { return nil }
        displaySleepAttempts = min(displaySleepAttempts + 1, 4)
        nextDisplaySleep = now + [1.0, 2.0, 5.0, 30.0][displaySleepAttempts - 1]
        return .displaySleep
    }

    mutating func willSleep() {
        pendingSleep = false
        finishDisplaySleep()
    }

    mutating func didWake() {
        // A wake/restart takes the current lid position as a baseline. An
        // already-closed lid is not evidence that the user just closed it.
        previous = nil
        finishDisplaySleep()
    }

    mutating func plan(_ sample: PolicySample, now: Double) -> [PolicyAction] {
        var actions: [PolicyAction] = []
        trackDisplayOff(sample)
        let dockedOff = dockedScreenOff(sample)
        if sample.externalDisplayConnected == true && !dockedOff {
            // Attaching a monitor supersedes any pending undocked lid action,
            // including one queued before the display finished enumerating.
            pendingSleep = false
            finishDisplaySleep()
            closureLocked = false
            lockAttempts = 0
            lockExhaustedReported = false
        }
        // macOS owns idle locking and display idle. HID idle readings are
        // diagnostic only: docks, video, and passive reading must not trigger
        // an autonomous lock or display-off request here.
        let awakeNow = awakeRequired(sample)
        guard let awake = awakeNow, let closed = sample.lidClosed,
              sample.sleepDisabled != nil,
              sample.externalDisplayConnected != nil, (awake || sample.known) else {
            // Positive keep-awake evidence can prevent sleep during an unknown
            // read; disruptive actions wait for the required sensors.
            if awakeNow == true && sample.sleepDisabled == false && now >= nextEnforce {
                actions.append(.setSleepDisabled(true))
                nextEnforce = now + 2
            }
            if let display = displaySleepAction(sample, now: now) { actions.append(display) }
            if unknownReported { return actions }
            unknownReported = true
            actions.append(.log("sensor state unknown; never clearing inhibition or requesting sleep"))
            return actions
        }
        if unknownReported { actions.append(.log("sensor readings recovered")) }
        unknownReported = false
        let initial = previous == nil
        // Removing the dock's display ends its usable-session exception even
        // when the hinge never moved. Restore undocked lock/blank behavior.
        let newClosure = closed && sample.externalDisplayConnected == false
            && (previous?.lidClosed == false || previous?.externalDisplayConnected == true)
        let externalChanged = sample.externalDisplayConnected.map { previous?.externalDisplayConnected != $0 } ?? false
        let policyChanged = previous?.externalPower != sample.externalPower || previous?.caffeinate != sample.caffeinate
            || externalChanged || (!initial && previousDockedScreenOff != dockedOff)
        // A docked closure matters only once rows 7 and 8 allow sleep.
        let closing = closed && previous?.lidClosed == false
        let needsSleep = closed && !awake && (initial || newClosure || closing || policyChanged)

        if !closed {
            closureLocked = false
            lockAttempts = 0
            lockExhaustedReported = false
            pendingSleep = false
            pendingLidDisplaySleep = false
        }
        if initial || newClosure || policyChanged {
            enforceAttempts = 0
            nextEnforce = now
        }
        if awake { pendingSleep = false }
        if needsSleep {
            pendingSleep = true
            sleepAttempts = 0
            nextSleep = now
        }
        if newClosure {
            pendingLidDisplaySleep = true
            displaySleepAttempts = 0
            nextDisplaySleep = now
        }
        if newClosure || needsSleep {
            closureLocked = sample.screenLocked == true
            lockAttempts = 0
            nextLock = now
            lockExhaustedReported = false
        }
        previous = sample
        previousDockedScreenOff = dockedOff

        if closed && !closureLocked && (pendingLidDisplaySleep || pendingSleep) {
            if sample.screenLocked == true {
                closureLocked = true
                actions.append(.log("screen lock verified for closed lid"))
            } else if sample.externalDisplayConnected == false && now >= nextLock {
                // Docked, macOS locks as the monitor turns off; the runtime
                // refuses an agent lock while a monitor is connected.
                if !actions.contains(.lock) { actions.append(.lock) }
                lockAttempts = min(lockAttempts + 1, 4)
                nextLock = now + [1.0, 2.0, 5.0, 30.0][lockAttempts - 1]
            }
            if lockAttempts >= 3 && !lockExhaustedReported {
                actions.append(.log(sample.sleepLockImmediate
                    ? "native lock not verified; confirmed immediate screenLock permits secure system-sleep fallback"
                    : "screen lock not verified; continuing retries with capped backoff; no secure sleep fallback available"))
                lockExhaustedReported = true
            }
        }

        // Docked screen-off: with an immediate password, sleep locks the session
        // even if the lock-screen flag has not been read as set yet.
        let secureSleep = closureLocked || (sample.sleepLockImmediate && (lockAttempts >= 3 || dockedOff))

        if sample.sleepDisabled == awake {
            enforceAttempts = 0
            nextEnforce = now
        } else if awake || !closed || secureSleep {
            // Lock before clearing the bit with the lid closed: macOS may sleep
            // immediately when the global inhibition is removed.
            if now >= nextEnforce {
                actions.append(.setSleepDisabled(awake))
                enforceAttempts = min(enforceAttempts + 1, 4)
                nextEnforce = now + [2.0, 4.0, 8.0, 30.0][enforceAttempts - 1]
            }
        }

        if let display = displaySleepAction(sample, now: now) { actions.append(display) }

        if pendingSleep && secureSleep && sample.sleepDisabled == false {
            if now >= nextSleep {
                actions.append(.sleep)
                sleepAttempts = min(sleepAttempts + 1, 3)
                nextSleep = now + [5.0, 10.0, 30.0][sleepAttempts - 1]
            }
        }
        return actions
    }
}

struct CommandResult {
    var status: Int32
    var output: String
}

// Paths are configurable for read-only checks and fake-command integration
// testing. Arguments never pass through a shell.
struct Configuration {
    var mode = "--status"
    var dryRun = false
    var interval = 1.0
    var pmset = "/usr/bin/pmset"
    var sudo = "/usr/bin/sudo"
    var sysadminctl = "/usr/sbin/sysadminctl"
    var allowDisplayLockFallback = false

    static func parse(_ arguments: [String]) throws -> Configuration {
        var config = Configuration()
        var i = 0
        var modeSet = false
        while i < arguments.count {
            let argument = arguments[i]
            switch argument {
            case "--run", "--once", "--status", "--check":
                guard !modeSet else { throw PolicyError("choose one execution mode") }
                config.mode = argument
                modeSet = true
            case "--dry-run": config.dryRun = true
            case "--allow-display-lock-fallback": config.allowDisplayLockFallback = true
            case "--pmset-path", "--sudo-path", "--sysadminctl-path", "--interval":
                i += 1
                guard i < arguments.count else { throw PolicyError("missing value for \(argument)") }
                let value = arguments[i]
                if argument == "--interval" {
                    guard let interval = Double(value), interval >= 0.1, interval <= 1 else {
                        throw PolicyError("interval must be between 0.1 and 1 second")
                    }
                    config.interval = interval
                } else {
                    guard value.hasPrefix("/") else { throw PolicyError("command paths must be absolute") }
                    if argument == "--pmset-path" { config.pmset = value }
                    if argument == "--sudo-path" { config.sudo = value }
                    if argument == "--sysadminctl-path" { config.sysadminctl = value }
                }
            case "--help", "-h": throw PolicyError(usage)
            default: throw PolicyError("unknown argument: \(argument)")
            }
            i += 1
        }
        guard config.mode != "--once" || config.dryRun else {
            throw PolicyError("--once requires --dry-run; use --run for the live policy")
        }
        return config
    }

    static let usage = """
    power-policy [--status | --check | --run | --once --dry-run]
      --dry-run                         log actions without locking or changing power
      --interval SECONDS                polling interval, 0.1...1 (default 1)
      --pmset-path ABSOLUTE_PATH         default /usr/bin/pmset
      --sudo-path ABSOLUTE_PATH          default /usr/bin/sudo
      --sysadminctl-path ABSOLUTE_PATH   default /usr/sbin/sysadminctl
      --allow-display-lock-fallback     only if screenLock is currently immediate
    """
}

struct PolicyError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func runCommand(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
        // Small system commands should finish immediately. A timeout also
        // protects launchd's polling loop from a broken substitute command.
        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        return CommandResult(status: -1, output: String(describing: error))
    }
}

func registryProperties(_ className: String, keys: [String]) -> [String: Bool] {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
    guard service != 0 else { return [:] }
    defer { IOObjectRelease(service) }
    var result: [String: Bool] = [:]
    for key in keys {
        if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            result[key] = value.boolValue
        }
    }
    return result
}

// Same UID + exact executable path + a live BSD process record. A process named
// 'caffeinate' elsewhere, a shell mentioning it, or a zombie is not an override.
func caffeinateProcesses(uid: uid_t = getuid()) -> [pid_t]? {
    for _ in 0..<3 {
        let size = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard size > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 64)
        let capacity = pids.count * MemoryLayout<pid_t>.stride
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32(capacity))
        }
        guard bytes > 0 else { return nil }
        if bytes >= capacity { continue }
        var matches: [pid_t] = []
        var unreadable = false
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride) where pid > 0 {
            var info = proc_bsdinfo()
            errno = 0
            let infoSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            // An exited/incomplete BSD record cannot represent a live override.
            guard infoSize == MemoryLayout<proc_bsdinfo>.size else { continue }
            guard info.pbi_uid == uid, info.pbi_status != UInt32(SZOMB) else { continue }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard name == "caffeinate" else { continue }
            // PROC_PIDPATHINFO_MAXSIZE is 4*MAXPATHLEN; that C macro is not
            // imported by Swift because MAXPATHLEN is an expression.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            errno = 0
            let pathSize = proc_pidpath(pid, &path, UInt32(path.count))
            guard pathSize > 0 else {
                if errno != ESRCH { unreadable = true }
                continue
            }
            if String(cString: path) == "/usr/bin/caffeinate" { matches.append(pid) }
        }
        if !matches.isEmpty { return matches.sorted() }
        return unreadable ? nil : []
    }
    return nil
}

func screenLocked() -> Bool? {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
}

func isUsableExternalDisplay(builtIn: Bool, vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
    guard !builtIn else { return false }
    // BetterDisplay/WindowServer can leave this exact fallback display online
    // after the physical monitor detaches. Do not generalize this exclusion:
    // generic IDs, real USB/DisplayLink output, and mirrors must keep working.
    return !(vendor == 0x756e6b6e && model == 0x76697274 && serial == 0)
}

struct DisplayReading {
    let onlineIDs: [CGDirectDisplayID]?
    let externalIDs: [CGDirectDisplayID]?
    let ignoredVirtualIDs: [CGDirectDisplayID]?
    let asleep: Bool?

    var externalConnected: Bool? { externalIDs.map { !$0.isEmpty } }

    static func read() -> DisplayReading {
        var displays = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
              count > 0, count < displays.count else {
            // Empty/failed enumeration during hotplug is unknown, never proof
            // that a monitor detached and a closed-lid Mac should sleep.
            return DisplayReading(onlineIDs: nil, externalIDs: nil, ignoredVirtualIDs: nil, asleep: nil)
        }
        let online = Array(displays.prefix(Int(count)))
        // Keep mirrored displays: a real external monitor can be a mirror.
        // Apart from the exact observed fallback signature, public CG cannot
        // reliably separate virtual output from valid DisplayLink/USB output.
        var external: [CGDirectDisplayID] = []
        var ignored: [CGDirectDisplayID] = []
        for id in online {
            let builtIn = CGDisplayIsBuiltin(id) != 0
            if isUsableExternalDisplay(builtIn: builtIn, vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id)) {
                external.append(id)
            } else if !builtIn { ignored.append(id) }
        }
        return DisplayReading(onlineIDs: online, externalIDs: external, ignoredVirtualIDs: ignored,
                              asleep: online.allSatisfy { CGDisplayIsAsleep($0) != 0 })
    }
}

struct HardwareReading {
    let sample: PolicySample
    let battery: [String: Bool]
    let caffeinatePIDs: [pid_t]?
    let displays: DisplayReading

    static func read(sleepLockImmediate: Bool = false) -> HardwareReading {
        let battery = registryProperties("AppleSmartBattery", keys: ["AppleRawExternalConnected", "ExternalConnected"])
        let root = registryProperties("IOPMrootDomain", keys: ["AppleClamshellState", "SleepDisabled"])
        let pids = caffeinateProcesses()
        let displays = DisplayReading.read()
        // Raw input remains physical while AlDente can simulate disconnection
        // for discharge. Older hardware falls back to ExternalConnected.
        let external = battery["AppleRawExternalConnected"] ?? battery["ExternalConnected"]
        return HardwareReading(sample: PolicySample(externalPower: external,
            lidClosed: root["AppleClamshellState"], caffeinate: pids.map { !$0.isEmpty },
            sleepDisabled: root["SleepDisabled"], screenLocked: screenLocked(),
            idleSeconds: CGEventType(rawValue: UInt32.max).map {
                CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
            }, sleepLockImmediate: sleepLockImmediate, displaysAsleep: displays.asleep,
            externalDisplayConnected: displays.externalConnected),
            battery: battery, caffeinatePIDs: pids, displays: displays)
    }
}

final class ScreenLocker {
    // Private API, also used by Hammerspoon. Chromium documents the return as
    // OSStatus (Int32). The return is logged; session state is the verification.
    // https://chromium.googlesource.com/chromium/src/+/refs/heads/main/base/mac/login_util.cc
    private let handle: UnsafeMutableRawPointer?
    private let function: (@convention(c) () -> Int32)?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY | RTLD_LOCAL)
        if let handle, let symbol = dlsym(handle, "SACLockScreenImmediate") {
            function = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        } else { function = nil }
    }

    var available: Bool { function != nil }

    func sleepLocksImmediately(config: Configuration) -> Bool {
        let setting = runCommand(config.sysadminctl, ["-screenLock", "status"])
        return setting.status == 0 && setting.output.lowercased().contains("delay is immediate")
    }

    func request(config: Configuration) -> String {
        if let function { return "native screen lock requested (status \(function())); awaiting session verification" }
        if config.allowDisplayLockFallback {
            if sleepLocksImmediately(config: config) {
                let result = runCommand(config.pmset, ["displaysleepnow"])
                return "immediate-lock display fallback requested (status \(result.status)); awaiting session verification: \(result.output)"
            }
        }
        return "screen lock unavailable; no display fallback with unverified security settings"
    }
}

func logPolicy(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

final class PolicyRuntime {
    let config: Configuration
    let locker: ScreenLocker
    var engine = PolicyEngine()
    var timer: Timer?
    var observers: [NSObjectProtocol] = []
    private var lastSummary = ""
    private var sleepLockImmediate: Bool
    private var attachmentTracker = DisplayAttachmentTracker()
    private var pendingAttachmentWake = PendingAttachmentWake()
    private var attachmentWakeWaitingLogged = false
    private var userActivityAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var displayCallbackRegistered = false
    private var powerSettle = PowerSettle()

    // Every reading the engine or a fresh re-check sees carries the settled
    // charger state, never a one-second hub flicker.
    private func read() -> (reading: HardwareReading, chargerReading: Bool?) {
        let raw = HardwareReading.read(sleepLockImmediate: sleepLockImmediate)
        var sample = raw.sample
        sample.externalPower = powerSettle.update(raw.sample.externalPower, now: ProcessInfo.processInfo.systemUptime)
        return (HardwareReading(sample: sample, battery: raw.battery, caffeinatePIDs: raw.caffeinatePIDs,
                                displays: raw.displays), raw.sample.externalPower)
    }

    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard !flags.contains(.beginConfigurationFlag), let context else { return }
        let runtime = Unmanaged<PolicyRuntime>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { runtime.tick() }
    }

    init(config: Configuration, locker: ScreenLocker) {
        self.config = config
        self.locker = locker
        sleepLockImmediate = locker.sleepLocksImmediately(config: config)
    }

    func tick() {
        let (reading, chargerReading) = read()
        let sample = reading.sample
        let newlyAttached = attachmentTracker.newlyAttached(reading.displays.externalIDs)
        if !newlyAttached.isEmpty {
            pendingAttachmentWake.enqueue(newlyAttached, now: ProcessInfo.processInfo.systemUptime)
            attachmentWakeWaitingLogged = false
            logPolicy("queued attachment display wake for up to 5 seconds: \(newlyAttached)")
        }
        let summary = "charger=\(sample.externalPower.map(String.init) ?? "unknown") chargerReading=\(chargerReading.map(String.init) ?? "unknown") lidClosed=\(sample.lidClosed.map(String.init) ?? "unknown") caffeinate=\(sample.caffeinate.map(String.init) ?? "unknown") externalDisplay=\(sample.externalDisplayConnected.map(String.init) ?? "unknown") disablesleep=\(sample.sleepDisabled.map(String.init) ?? "unknown")"
        if summary != lastSummary { logPolicy(summary); lastSummary = summary }
        for action in engine.plan(sample, now: ProcessInfo.processInfo.systemUptime) {
            switch action {
            case .log(let message): logPolicy(message)
            case .lock:
                let fresh = read().reading.sample
                guard canRequestLock(sample: fresh) else {
                    logPolicy("aborted stale lock plan; lid opened or no confirmed undocked lock permission remains")
                    continue
                }
                if config.dryRun { logPolicy("dry run: request screen lock") }
                else { logPolicy(locker.request(config: config)) }
            case .displaySleep:
                let fresh = read().reading.sample
                guard canDisplaySleep(sample: fresh) else {
                    if fresh.lidClosed == false || fresh.externalDisplayConnected == true { engine.cancelDisplaySleep() }
                    logPolicy("aborted stale lid display-off plan after fresh lock/lid/external-display check")
                    continue
                }
                if config.dryRun { logPolicy("dry run: \(config.pmset) displaysleepnow (lidClosed)") }
                else {
                    let result = runCommand(config.pmset, ["displaysleepnow"])
                    logPolicy("display-off request for lidClosed status=\(result.status); awaiting display-asleep verification \(result.output)")
                }
            case .setSleepDisabled(let disabled):
                if !disabled {
                    let fresh = read().reading.sample
                    guard fresh.known && engine.awakeRequired(fresh) == false else {
                        logPolicy("aborted stale inhibition-release plan; current lid/Coffee/dock policy or unknown sensor requires protection")
                        continue
                    }
                    if fresh.lidClosed == true && fresh.screenLocked != true {
                        sleepLockImmediate = locker.sleepLocksImmediately(config: config)
                        guard sleepLockImmediate else { logPolicy("aborted inhibition release without confirmed secure lock fallback"); continue }
                    }
                }
                let arguments = ["-n", config.pmset, "disablesleep", disabled ? "1" : "0"]
                if config.dryRun { logPolicy("dry run: \(config.sudo) \(arguments.joined(separator: " "))") }
                else {
                    let result = runCommand(config.sudo, arguments)
                    logPolicy("set disablesleep=\(disabled ? 1 : 0) status=\(result.status) \(result.output)")
                }
            case .sleep:
                let fresh = read().reading.sample
                guard fresh.known && engine.awakeRequired(fresh) == false && fresh.lidClosed == true && fresh.sleepDisabled == false else {
                    logPolicy("aborted stale sleep plan after fresh power/lid/Coffee/external-display check")
                    continue
                }
                if fresh.screenLocked != true {
                    sleepLockImmediate = locker.sleepLocksImmediately(config: config)
                    guard sleepLockImmediate else { logPolicy("aborted sleep without confirmed secure lock fallback"); continue }
                }
                if config.dryRun { logPolicy("dry run: \(config.pmset) sleepnow") }
                else {
                    let result = runCommand(config.pmset, ["sleepnow"])
                    logPolicy("explicit lid sleep request status=\(result.status); awaiting sleep notification: \(result.output)")
                }
            }
        }
        // Hotplug enumeration and the keep-awake write may settle on different
        // ticks. Wait briefly for readiness, but make only one actual IOPM call.
        // Native display/system sleep notifications cancel the pending request.
        if !pendingAttachmentWake.isEmpty {
            let fresh = read().reading
            let candidates = pendingAttachmentWake.candidates(currentIDs: fresh.displays.externalIDs,
                now: ProcessInfo.processInfo.systemUptime)
            guard !candidates.isEmpty else {
                logPolicy("pending attachment wake expired or monitor detached")
                attachmentWakeWaitingLogged = false
                return
            }
            guard canWakeAttachedDisplays(candidates, currentIDs: fresh.displays.externalIDs, sample: fresh.sample) else {
                if !attachmentWakeWaitingLogged {
                    logPolicy("attachment wake waiting briefly for confirmed display IDs and disablesleep=1: \(candidates)")
                    attachmentWakeWaitingLogged = true
                }
                return
            }
            if config.dryRun { logPolicy("dry run: declare local user activity for attached displays \(candidates)") }
            else {
                let result = IOPMAssertionDeclareUserActivity(
                    "External monitor attached" as CFString, kIOPMUserActiveLocal, &userActivityAssertionID)
                logPolicy("attachment display wake status=\(result) assertion=\(userActivityAssertionID) externalIDs=\(candidates)")
            }
            pendingAttachmentWake.attempted(candidates)
            attachmentWakeWaitingLogged = false
        }
    }

    func run() {
        let registration = CGDisplayRegisterReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
        displayCallbackRegistered = registration == .success
        if !displayCallbackRegistered { logPolicy("display callback registration failed: \(registration.rawValue); using timer fallback") }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.willSleep()
            self?.pendingAttachmentWake.cancel()
            logPolicy("system sleep notification observed")
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pendingAttachmentWake.cancel()
            logPolicy("display sleep notification observed; cancelled pending attachment wake")
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.didWake()
            logPolicy("system wake notification observed; reconciling")
            self?.tick()
        })
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: config.interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.run()
    }

    deinit {
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }
}

#if !POWER_POLICY_TESTS
@main
struct PowerPolicyMain {
    static func main() {
        do {
            let config = try Configuration.parse(Array(CommandLine.arguments.dropFirst()))
            let locker = ScreenLocker()
            if config.mode == "--status" || config.mode == "--check" {
                let immediate = locker.sleepLocksImmediately(config: config)
                let reading = HardwareReading.read(sleepLockImmediate: immediate)
                let sample = reading.sample
                let object: [String: Any] = [
                    "physicalChargerConnected": sample.externalPower as Any? ?? NSNull(),
                    "batteryPowerSensors": reading.battery,
                    "lidClosed": sample.lidClosed as Any? ?? NSNull(),
                    "caffeinatePIDs": reading.caffeinatePIDs as Any? ?? NSNull(),
                    "sleepDisabled": sample.sleepDisabled as Any? ?? NSNull(),
                    "screenLocked": sample.screenLocked as Any? ?? NSNull(),
                    "displaysAsleep": sample.displaysAsleep as Any? ?? NSNull(),
                    "externalDisplayConnected": sample.externalDisplayConnected as Any? ?? NSNull(),
                    "onlineDisplayIDs": reading.displays.onlineIDs as Any? ?? NSNull(),
                    "externalDisplayIDs": reading.displays.externalIDs as Any? ?? NSNull(),
                    "ignoredVirtualDisplayIDs": reading.displays.ignoredVirtualIDs as Any? ?? NSNull(),
                    "awakeRequired": sample.awakeRequired as Any? ?? NSNull(),
                    "nativeScreenLockAvailable": locker.available,
                    "idleSeconds": sample.idleSeconds as Any? ?? NSNull(),
                    "idlePolicy": "macOS",
                    "sleepLocksImmediately": immediate,
                    "sensorsKnown": sample.known
                ]
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                if config.mode == "--check" {
                    guard sample.known else { throw PolicyError("required sensor or process reading unavailable") }
                    guard FileManager.default.isExecutableFile(atPath: config.pmset), FileManager.default.isExecutableFile(atPath: config.sudo) else {
                        throw PolicyError("pmset or sudo executable unavailable")
                    }
                    guard locker.available else { throw PolicyError("native screen lock API unavailable; fallback requires separate verification") }
                    for value in ["0", "1"] {
                        let permission = runCommand(config.sudo, ["-n", "-l", "--", config.pmset, "disablesleep", value])
                        guard permission.status == 0 else {
                            throw PolicyError("missing noninteractive permission for pmset disablesleep \(value): \(permission.output)")
                        }
                    }
                }
            } else {
                let runtime = PolicyRuntime(config: config, locker: locker)
                if config.mode == "--once" { runtime.tick() } else { runtime.run() }
            }
        } catch {
            logPolicy(String(describing: error))
            exit(1)
        }
    }
}
#endif

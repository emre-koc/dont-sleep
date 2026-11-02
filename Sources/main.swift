import AppKit
import IOKit.hid
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Power control

/// Wraps `pmset disablesleep` (needed for lid-closed, on-battery wake) plus an
/// idle-sleep assertion. Root access comes from a narrow sudoers rule that is
/// installed once, with a single admin password prompt.
final class PowerManager {
    static let sudoersPath = "/etc/sudoers.d/dont-sleep"
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    /// Current system value of `SleepDisabled` from `pmset -g`.
    func isSleepDisabled() -> Bool {
        let out = run("/usr/bin/pmset", ["-g"]).output
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return false
    }

    /// Returns true when the system ended up in the requested state.
    @discardableResult
    func setAwake(_ awake: Bool) -> Bool {
        if !pmset(awake) {
            guard installSudoersRule(), pmset(awake) else { return false }
        }
        awake ? holdAssertion() : releaseAssertion()
        return true
    }

    private func pmset(_ awake: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", awake ? "1" : "0"]).status == 0
    }

    /// Puts the Mac to sleep right away. Restoring normal sleep alone isn't enough when the lid
    /// is already closed: macOS only sleeps at the moment the lid closes, and other apps' idle
    /// assertions can keep it awake indefinitely.
    func sleepNow() {
        if run("/usr/bin/pmset", ["sleepnow"]).status != 0 {
            _ = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "sleepnow"])
        }
    }

    private func installSudoersRule() -> Bool {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow"
        let shell = """
        mkdir -p /etc/sudoers.d && T=$(mktemp /etc/sudoers.d/.dont-sleep.XXXXXX) && \
        printf '%s\\n' '\(rule)' > "$T" && /usr/sbin/visudo -cf "$T" >/dev/null && \
        chown root:wheel "$T" && chmod 440 "$T" && mv -f "$T" \(Self.sudoersPath) || { rm -f "$T"; exit 1; }
        """
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        do shell script "\(escaped)" with prompt "DontSleep needs permission once to control lid-close sleep." with administrator privileges
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    private func holdAssertion() {
        guard !hasAssertion else { return }
        hasAssertion = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "DontSleep: eyes open" as CFString,
            &assertionID) == kIOReturnSuccess
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
    }

    private func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Battery

/// Battery percentage when running on battery, nil when on AC or no battery.
func batteryPercentOnBattery() -> Int? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
              let cur = desc[kIOPSCurrentCapacityKey] as? Int,
              let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        return cur * 100 / max
    }
    return nil
}

/// Battery pack temperature in °C, from the AppleSmartBattery driver (works on Intel and Apple Silicon).
func batteryTemperature() -> Double? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let raw = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Int, raw > 0 else { return nil }
    return Double(raw) / 100
}

/// True when the lid is closed and no external display is in use, i.e. the Mac is in a bag rather
/// than running closed on a desk with a monitor.
func isClosedWithoutDisplay() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    let closed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool ?? false
    var displays: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displays)
    return closed && displays == 0
}

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "heatGuard": true, "heatLimit": 85.0, "pressureGuard": true,
            "batteryGuard": true, "batteryLimit": 25,
            "batteryHeatGuard": true, "batteryHeatLimit": 40.0,
            "uprightGuard": true, "uprightMinutes": 15,
            "eyesLookAway": true,
        ])
        // v1.2 raised the low-battery default from 10 % to 25 %; move anyone still on the old default.
        if defaults.integer(forKey: "settingsVersion") < 2 {
            if defaults.object(forKey: "batteryLimit") as? Int == 10 { defaults.removeObject(forKey: "batteryLimit") }
            defaults.set(2, forKey: "settingsVersion")
        }
    }

    var heatGuard: Bool {
        get { defaults.bool(forKey: "heatGuard") }
        set { defaults.set(newValue, forKey: "heatGuard") }
    }
    /// Chip temperature (°C) above which the eyes close.
    var heatLimit: Double {
        get { defaults.double(forKey: "heatLimit") }
        set { defaults.set(newValue, forKey: "heatLimit") }
    }
    /// Also close the eyes when macOS reports serious/critical thermal pressure.
    var pressureGuard: Bool {
        get { defaults.bool(forKey: "pressureGuard") }
        set { defaults.set(newValue, forKey: "pressureGuard") }
    }
    /// Open eyes look away from the mouse pointer.
    var eyesLookAway: Bool {
        get { defaults.bool(forKey: "eyesLookAway") }
        set { defaults.set(newValue, forKey: "eyesLookAway") }
    }
    var batteryGuard: Bool {
        get { defaults.bool(forKey: "batteryGuard") }
        set { defaults.set(newValue, forKey: "batteryGuard") }
    }
    var batteryLimit: Int {
        get { defaults.integer(forKey: "batteryLimit") }
        set { defaults.set(newValue, forKey: "batteryLimit") }
    }
    var batteryHeatGuard: Bool {
        get { defaults.bool(forKey: "batteryHeatGuard") }
        set { defaults.set(newValue, forKey: "batteryHeatGuard") }
    }
    /// Battery temperature (°C) above which the eyes close.
    var batteryHeatLimit: Double {
        get { defaults.double(forKey: "batteryHeatLimit") }
        set { defaults.set(newValue, forKey: "batteryHeatLimit") }
    }
    /// Sleep when the closed Mac has been standing on its side (as in a bag) for a while.
    var uprightGuard: Bool {
        get { defaults.bool(forKey: "uprightGuard") }
        set { defaults.set(newValue, forKey: "uprightGuard") }
    }
    var uprightMinutes: Int {
        get { defaults.integer(forKey: "uprightMinutes") }
        set { defaults.set(newValue, forKey: "uprightMinutes") }
    }
}

// MARK: - Temperature

/// Reads chip die temperatures through the IOHIDEventSystem (the same source
/// tools like Stats use). The API is private, so it is loaded with dlsym and
/// everything degrades to "unavailable" if a symbol is missing.
final class ThermalMonitor {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    private var client: UnsafeMutableRawPointer?
    private var sensors: [AnyObject] = []
    private var recent: [Double] = []
    private let window = 3

    var isAvailable: Bool { !sensors.isEmpty }

    init() {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(lib, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(lib, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(lib, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(lib, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(lib, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(lib, "IOHIDEventGetFloatValue") else { return }
        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloatFn.self)

        guard let client = unsafeBitCast(create, to: CreateFn.self)(kCFAllocatorDefault) else { return }
        self.client = client
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, matching)
        guard let all = unsafeBitCast(copyServices, to: CopyServicesFn.self)(client)?
            .takeRetainedValue() as [AnyObject]? else { return }

        let named: [(String, AnyObject)] = all.map { service in
            let ptr = UnsafeRawPointer(Unmanaged.passUnretained(service).toOpaque())
            let name = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)(ptr, "Product" as CFString)?
                .takeRetainedValue() as? String ?? ""
            return (name, service)
        }
        // Prefer the SoC die sensors; fall back to any PMU sensor.
        let die = named.filter { $0.0.hasPrefix("PMU tdie") }
        sensors = (die.isEmpty ? named.filter { $0.0.hasPrefix("PMU") } : die).map(\.1)
    }

    /// Hottest chip sensor right now, in °C.
    func current() -> Double? {
        guard let copyEvent, let getFloat else { return nil }
        var hottest: Double?
        for service in sensors {
            let ptr = UnsafeRawPointer(Unmanaged.passUnretained(service).toOpaque())
            guard let event = copyEvent(ptr, Self.temperatureEvent, 0, 0) else { continue }
            let value = getFloat(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(event).release()
            if value > 0, value < 150 { hottest = max(hottest ?? value, value) }
        }
        return hottest
    }

    /// Takes a reading and returns the average of the last few, so a short spike doesn't trip the limit.
    func sample() -> Double? {
        guard let now = current() else { return nil }
        recent.append(now)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        return recent.reduce(0, +) / Double(recent.count)
    }
}

// MARK: - Motion

/// Reads the built-in accelerometer. Apple Silicon MacBooks expose it as an SPU HID device
/// (usage page 0xFF00, usage 3); each 22-byte report holds x, y, z as Int32 in 1/65536 g at
/// offsets 6, 10 and 14. No special permission is needed. The sensor is only powered while
/// something has acquired it.
final class MotionMonitor {
    private static let usagePage = 0xff00, usage = 3
    private static let reportInterval = 1_000_000 // µs: one report per second is plenty

    private var manager: IOHIDManager?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var users = 0
    private var gravity: (x: Double, y: Double, z: Double)?
    private var lastReport = Date.distantPast

    var isAvailable: Bool { !drivers().isEmpty }

    /// Degrees away from lying flat: 0 when flat on a table, 90 when standing on an edge.
    /// Nil when there's no fresh reading or the Mac is being moved around.
    var tilt: Double? {
        guard let g = gravity, Date().timeIntervalSince(lastReport) < 5 else { return nil }
        let magnitude = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard magnitude > 0.7, magnitude < 1.3 else { return nil }
        return acos(min(1, abs(g.z) / magnitude)) * 180 / .pi
    }

    func acquire() {
        users += 1
        if users == 1 { start() }
    }

    func release() {
        guard users > 0 else { return }
        users -= 1
        if users == 0 { stop() }
    }

    private func drivers() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let page = IORegistryEntryCreateCFProperty(service, "PrimaryUsagePage" as CFString, nil, 0)?
                .takeRetainedValue() as? Int
            let usage = IORegistryEntryCreateCFProperty(service, "PrimaryUsage" as CFString, nil, 0)?
                .takeRetainedValue() as? Int
            if page == Self.usagePage, usage == Self.usage { found.append(service) } else { IOObjectRelease(service) }
        }
        return found
    }

    private func configureDrivers(on: Bool) {
        for driver in drivers() {
            IORegistryEntrySetCFProperty(driver, "SensorPropertyReportingState" as CFString, (on ? 1 : 0) as CFNumber)
            IORegistryEntrySetCFProperty(driver, "SensorPropertyPowerState" as CFString, (on ? 1 : 0) as CFNumber)
            IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString,
                                         (on ? Self.reportInterval : 0) as CFNumber)
            IOObjectRelease(driver)
        }
    }

    private func start() {
        configureDrivers(on: true)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: Self.usagePage,
                                                kIOHIDPrimaryUsageKey: Self.usage] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
                guard let context, length >= 18 else { return }
                Unmanaged<MotionMonitor>.fromOpaque(context).takeUnretainedValue().handle(report, length)
            }, context)
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
    }

    private func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        gravity = nil
        configureDrivers(on: false)
    }

    private func handle(_ report: UnsafeMutablePointer<UInt8>, _ length: Int) {
        func axis(_ offset: Int) -> Double {
            var raw: Int32 = 0
            memcpy(&raw, report + offset, 4)
            return Double(Int32(littleEndian: raw)) / 65536
        }
        gravity = (axis(6), axis(10), axis(14))
        lastReport = Date()
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings = Settings.shared
    private let thermal: ThermalMonitor
    private let motion: MotionMonitor
    private let onChange: () -> Void
    private var liveTimer: Timer?
    private var watchingMotion = false

    private let heatCheck = NSButton(checkboxWithTitle: "Close eyes when the Mac gets too hot", target: nil, action: nil)
    private let heatSlider = NSSlider(value: 85, minValue: 60, maxValue: 105, target: nil, action: nil)
    private let heatValue = NSTextField(labelWithString: "")
    private let chipNow = NSTextField(labelWithString: "")
    private let pressureCheck = NSButton(checkboxWithTitle: "Also close eyes when macOS reports heavy thermal pressure",
                                         target: nil, action: nil)
    private let eyesCheck = NSButton(checkboxWithTitle: "Open eyes look away from the mouse pointer",
                                     target: nil, action: nil)
    private let batteryCheck = NSButton(checkboxWithTitle: "Close eyes when the battery is low", target: nil, action: nil)
    private let batterySlider = NSSlider(value: 25, minValue: 5, maxValue: 50, target: nil, action: nil)
    private let batteryValue = NSTextField(labelWithString: "")
    private let batteryHeatCheck = NSButton(checkboxWithTitle: "Close eyes when the battery gets too hot",
                                            target: nil, action: nil)
    private let batteryHeatSlider = NSSlider(value: 40, minValue: 30, maxValue: 50, target: nil, action: nil)
    private let batteryHeatValue = NSTextField(labelWithString: "")
    private let batteryNow = NSTextField(labelWithString: "")
    private let uprightCheck = NSButton(checkboxWithTitle: "Sleep when the Mac stands on its side in a bag",
                                        target: nil, action: nil)
    private let uprightSlider = NSSlider(value: 15, minValue: 5, maxValue: 60, target: nil, action: nil)
    private let uprightValue = NSTextField(labelWithString: "")
    private let positionNow = NSTextField(labelWithString: "")

    init(thermal: ThermalMonitor, motion: MotionMonitor, onChange: @escaping () -> Void) {
        self.thermal = thermal
        self.motion = motion
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 10),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DontSleep Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        load()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        load()
        updateChipNow()
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateChipNow() }
        if !watchingMotion {
            motion.acquire()
            watchingMotion = true
        }
        window?.center()
        showWindow(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        liveTimer?.invalidate()
        liveTimer = nil
        if watchingMotion {
            motion.release()
            watchingMotion = false
        }
    }

    private func buildContent() {
        for control in [eyesCheck, heatCheck, heatSlider, pressureCheck, batteryCheck, batterySlider,
                        batteryHeatCheck, batteryHeatSlider, uprightCheck, uprightSlider] as [NSControl] {
            control.target = self
            control.action = #selector(changed)
        }
        heatSlider.numberOfTickMarks = 10
        batterySlider.numberOfTickMarks = 10
        batteryHeatSlider.numberOfTickMarks = 11
        uprightSlider.numberOfTickMarks = 12
        for slider in [heatSlider, batterySlider, batteryHeatSlider, uprightSlider] {
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        for label in [heatValue, batteryValue, batteryHeatValue, uprightValue] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        chipNow.textColor = .secondaryLabelColor
        batteryNow.textColor = .secondaryLabelColor
        positionNow.textColor = .secondaryLabelColor

        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            return stack
        }

        let sleepNote = NSTextField(wrappingLabelWithString:
            "When a limit is reached with the lid closed, the eyes close and the Mac goes to sleep. "
            + "Standing on its side only counts while the lid is closed and no external display is connected.")
        sleepNote.textColor = .secondaryLabelColor
        sleepNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sleepNote.preferredMaxLayoutWidth = 400

        let stack = NSStackView(views: [
            header("Eyes"),
            eyesCheck,
            header("Heat"),
            heatCheck,
            row([NSTextField(labelWithString: "Limit"), heatSlider, heatValue]),
            row([chipNow]),
            pressureCheck,
            header("Battery"),
            batteryCheck,
            row([NSTextField(labelWithString: "Limit"), batterySlider, batteryValue]),
            batteryHeatCheck,
            row([NSTextField(labelWithString: "Limit"), batteryHeatSlider, batteryHeatValue]),
            row([batteryNow]),
            header("Motion"),
            uprightCheck,
            row([NSTextField(labelWithString: "After"), uprightSlider, uprightValue]),
            row([positionNow]),
            sleepNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: eyesCheck)
        stack.setCustomSpacing(18, after: pressureCheck)
        stack.setCustomSpacing(18, after: batteryNow.superview ?? batteryNow)
        stack.setCustomSpacing(18, after: positionNow.superview ?? positionNow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window?.contentView = stack
    }

    private func load() {
        eyesCheck.state = settings.eyesLookAway ? .on : .off
        heatCheck.state = settings.heatGuard ? .on : .off
        heatSlider.doubleValue = settings.heatLimit
        pressureCheck.state = settings.pressureGuard ? .on : .off
        batteryCheck.state = settings.batteryGuard ? .on : .off
        batterySlider.integerValue = settings.batteryLimit
        batteryHeatCheck.state = settings.batteryHeatGuard ? .on : .off
        batteryHeatSlider.doubleValue = settings.batteryHeatLimit
        uprightCheck.state = settings.uprightGuard ? .on : .off
        uprightSlider.integerValue = settings.uprightMinutes
        updateLabels()
    }

    @objc private func changed() {
        settings.eyesLookAway = eyesCheck.state == .on
        settings.heatGuard = heatCheck.state == .on
        settings.heatLimit = heatSlider.doubleValue.rounded()
        settings.pressureGuard = pressureCheck.state == .on
        settings.batteryGuard = batteryCheck.state == .on
        settings.batteryLimit = batterySlider.integerValue
        settings.batteryHeatGuard = batteryHeatCheck.state == .on
        settings.batteryHeatLimit = batteryHeatSlider.doubleValue.rounded()
        settings.uprightGuard = uprightCheck.state == .on
        settings.uprightMinutes = Int(uprightSlider.doubleValue.rounded())
        updateLabels()
        onChange()
    }

    private func updateLabels() {
        heatValue.stringValue = "\(Int(settings.heatLimit)) °C"
        batteryValue.stringValue = "\(settings.batteryLimit) %"
        heatSlider.isEnabled = settings.heatGuard && thermal.isAvailable
        batterySlider.isEnabled = settings.batteryGuard
        batteryHeatValue.stringValue = "\(Int(settings.batteryHeatLimit)) °C"
        batteryHeatSlider.isEnabled = settings.batteryHeatGuard
        uprightValue.stringValue = "\(settings.uprightMinutes) min"
        uprightSlider.isEnabled = settings.uprightGuard && motion.isAvailable
    }

    private func updateChipNow() {
        if let temp = thermal.current() {
            chipNow.stringValue = "Chip temperature now: \(Int(temp.rounded())) °C"
        } else {
            chipNow.stringValue = "Chip temperature sensor isn't available on this Mac."
        }
        if let temp = batteryTemperature() {
            batteryNow.stringValue = "Battery temperature now: \(Int(temp.rounded())) °C"
        } else {
            batteryNow.stringValue = "Battery temperature isn't available on this Mac."
        }
        if !motion.isAvailable {
            positionNow.stringValue = "This Mac has no motion sensor."
        } else if let tilt = motion.tilt {
            let position = tilt >= AppDelegate.uprightTilt ? "standing on its side" : tilt >= 30 ? "tilted" : "lying flat"
            positionNow.stringValue = "Position now: \(position) (\(Int(tilt.rounded()))° from flat)"
        } else {
            positionNow.stringValue = "Position now: reading the motion sensor…"
        }
    }
}

// MARK: - Eye tracking

/// Moves the pupils so they look away from the mouse pointer, easing toward each new direction.
/// Mouse-move monitoring needs no special permission (unlike key events).
final class EyeTracker {
    private let iconCenter: () -> NSPoint?
    private let draw: (CGVector) -> Void
    private var monitors: [Any] = []
    private var timer: Timer?
    private var target = EyeIcon.defaultLook
    private(set) var look = EyeIcon.defaultLook
    /// Distance (pt) from the icon at which the pupils reach full deflection.
    private let fullDeflection: CGFloat = 120

    init(iconCenter: @escaping () -> NSPoint?, draw: @escaping (CGVector) -> Void) {
        self.iconCenter = iconCenter
        self.draw = draw
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.pointerMoved()
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(local) }
        pointerMoved()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
    }

    private func pointerMoved() {
        guard let center = iconCenter() else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - center.x, dy = mouse.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return }
        // Opposite of the icon→mouse vector. Screen y points up and icon y points down,
        // so x flips sign and y keeps it.
        let strength = min(1, distance / fullDeflection)
        target = CGVector(dx: -dx / distance * strength, dy: dy / distance * strength)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        look.dx += (target.dx - look.dx) * 0.25
        look.dy += (target.dy - look.dy) * 0.25
        if hypot(target.dx - look.dx, target.dy - look.dy) < 0.01 {
            look = target
            timer?.invalidate()
            timer = nil
        }
        draw(look)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let power = PowerManager()
    private let thermal = ThermalMonitor()
    private let motion = MotionMonitor()
    /// Degrees from flat at which the Mac counts as standing on its side.
    static let uprightTilt: Double = 60
    /// When the closed Mac started standing on its side; nil while it isn't.
    private var uprightSince: Date?
    private var watchingMotion = false
    private let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private var awake = false
    /// Why the app closed the eyes on its own, shown in the menu until the user reopens them.
    private var autoCloseReason: String?
    private var safetyTimer: Timer?
    /// Keeps App Nap from delaying the safety checks while the Mac is kept awake.
    private var activity: NSObjectProtocol?
    private var sigterm: DispatchSourceSignal?
    private lazy var tracker = EyeTracker(
        iconCenter: { [weak self] in
            guard let frame = self?.statusItem.button?.window?.frame else { return nil }
            return NSPoint(x: frame.midX, y: frame.midY)
        },
        draw: { [weak self] look in
            self?.statusItem.button?.image = EyeIcon.make(open: true, look: look)
        })
    private lazy var settingsWindow = SettingsWindowController(thermal: thermal, motion: motion) { [weak self] in
        self?.checkSafety()
        self?.refresh()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Match reality: if sleep is already disabled (e.g. from a previous run), show open eyes.
        awake = power.isSleepDisabled()
        if awake { power.setAwake(true) }
        refresh()

        safetyTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkSafety()
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.checkSafety()
        }

        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        if awake { power.setAwake(false) }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        let target = !awake
        if target, let reason = blockReason(temperature: thermal.current()) {
            let alert = NSAlert()
            alert.messageText = "Can't stay awake right now"
            alert.informativeText = reason + ". You can change the limits in Settings."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Settings…")
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            if alert.runModal() == .alertSecondButtonReturn { showSettings() }
            return
        }
        if power.setAwake(target) {
            awake = target
            autoCloseReason = nil
        } else {
            NSSound.beep()
        }
        refresh()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// The reason staying awake isn't safe right now, or nil when it is.
    private func blockReason(temperature: Double?) -> String? {
        if settings.heatGuard, let temp = temperature, temp >= settings.heatLimit {
            return "The chip is at \(Int(temp.rounded())) °C, above your \(Int(settings.heatLimit)) °C limit"
        }
        if settings.pressureGuard {
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical {
                return "macOS reports heavy thermal pressure"
            }
        }
        if settings.batteryHeatGuard, let temp = batteryTemperature(), temp >= settings.batteryHeatLimit {
            return "The battery is at \(Int(temp.rounded())) °C, above your \(Int(settings.batteryHeatLimit)) °C limit"
        }
        if settings.batteryGuard, let pct = batteryPercentOnBattery(), pct <= settings.batteryLimit {
            return "The battery is at \(pct) %, at or below your \(settings.batteryLimit) % limit"
        }
        return nil
    }

    /// Set once the closed Mac has stood on its side for the configured time.
    private func uprightReason() -> String? {
        guard awake, settings.uprightGuard, let tilt = motion.tilt, tilt >= Self.uprightTilt,
              isClosedWithoutDisplay() else {
            uprightSince = nil
            return nil
        }
        let since = uprightSince ?? Date()
        uprightSince = since
        let minutes = settings.uprightMinutes
        guard Date().timeIntervalSince(since) >= Double(minutes) * 60 else { return nil }
        return "The Mac has been standing on its side with the lid closed for \(minutes) min"
    }

    private func checkSafety() {
        // Sample even while asleep-allowed so the average is warm when the eyes open.
        let temp = thermal.sample()
        guard awake, let reason = blockReason(temperature: temp) ?? uprightReason() else { return }
        if power.setAwake(false) {
            awake = false
            autoCloseReason = reason
            refresh()
            if isClosedWithoutDisplay() { power.sleepNow() }
        }
    }

    private func refresh() {
        let tracking = awake && settings.eyesLookAway
        statusItem.button?.image = awake
            ? EyeIcon.make(open: true, look: tracking ? tracker.look : EyeIcon.defaultLook)
            : EyeIcon.make(open: false)
        tracking ? tracker.start() : tracker.stop()
        let needsMotion = awake && settings.uprightGuard
        if needsMotion != watchingMotion {
            needsMotion ? motion.acquire() : motion.release()
            watchingMotion = needsMotion
            uprightSince = nil
        }
        if awake, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Watching temperature and battery while the Mac is kept awake")
        } else if !awake, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        statusItem.button?.toolTip = awake
            ? "Eyes open: Mac stays awake, even with the lid closed"
            : autoCloseReason.map { "Eyes closed automatically: \($0)" } ?? "Eyes closed: normal sleep"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        info(awake ? "Awake: lid-close sleep disabled" : "Normal sleep")
        if !awake, let reason = autoCloseReason { info("Closed automatically: \(reason)") }
        if let temp = thermal.current() { info("Chip: \(Int(temp.rounded())) °C") }
        if let temp = batteryTemperature() { info("Battery: \(Int(temp.rounded())) °C") }
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: awake ? "Close Eyes (allow sleep)" : "Open Eyes (stay awake)",
                                    action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DontSleep", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

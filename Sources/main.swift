import AppKit
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

    private func installSudoersRule() -> Bool {
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
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

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "heatGuard": true, "heatLimit": 85.0, "pressureGuard": true,
            "batteryGuard": true, "batteryLimit": 10,
        ])
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
    var batteryGuard: Bool {
        get { defaults.bool(forKey: "batteryGuard") }
        set { defaults.set(newValue, forKey: "batteryGuard") }
    }
    var batteryLimit: Int {
        get { defaults.integer(forKey: "batteryLimit") }
        set { defaults.set(newValue, forKey: "batteryLimit") }
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

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings = Settings.shared
    private let thermal: ThermalMonitor
    private let onChange: () -> Void
    private var liveTimer: Timer?

    private let heatCheck = NSButton(checkboxWithTitle: "Close eyes when the Mac gets too hot", target: nil, action: nil)
    private let heatSlider = NSSlider(value: 85, minValue: 60, maxValue: 105, target: nil, action: nil)
    private let heatValue = NSTextField(labelWithString: "")
    private let chipNow = NSTextField(labelWithString: "")
    private let pressureCheck = NSButton(checkboxWithTitle: "Also close eyes when macOS reports heavy thermal pressure",
                                         target: nil, action: nil)
    private let batteryCheck = NSButton(checkboxWithTitle: "Close eyes when the battery is low", target: nil, action: nil)
    private let batterySlider = NSSlider(value: 10, minValue: 5, maxValue: 50, target: nil, action: nil)
    private let batteryValue = NSTextField(labelWithString: "")

    init(thermal: ThermalMonitor, onChange: @escaping () -> Void) {
        self.thermal = thermal
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
        window?.center()
        showWindow(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func buildContent() {
        for control in [heatCheck, heatSlider, pressureCheck, batteryCheck, batterySlider] as [NSControl] {
            control.target = self
            control.action = #selector(changed)
        }
        heatSlider.numberOfTickMarks = 10
        batterySlider.numberOfTickMarks = 10
        for slider in [heatSlider, batterySlider] {
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        for label in [heatValue, batteryValue] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        chipNow.textColor = .secondaryLabelColor

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

        let stack = NSStackView(views: [
            header("Heat"),
            heatCheck,
            row([NSTextField(labelWithString: "Limit"), heatSlider, heatValue]),
            row([chipNow]),
            pressureCheck,
            header("Battery"),
            batteryCheck,
            row([NSTextField(labelWithString: "Limit"), batterySlider, batteryValue]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: pressureCheck)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window?.contentView = stack
    }

    private func load() {
        heatCheck.state = settings.heatGuard ? .on : .off
        heatSlider.doubleValue = settings.heatLimit
        pressureCheck.state = settings.pressureGuard ? .on : .off
        batteryCheck.state = settings.batteryGuard ? .on : .off
        batterySlider.integerValue = settings.batteryLimit
        updateLabels()
    }

    @objc private func changed() {
        settings.heatGuard = heatCheck.state == .on
        settings.heatLimit = heatSlider.doubleValue.rounded()
        settings.pressureGuard = pressureCheck.state == .on
        settings.batteryGuard = batteryCheck.state == .on
        settings.batteryLimit = batterySlider.integerValue
        updateLabels()
        onChange()
    }

    private func updateLabels() {
        heatValue.stringValue = "\(Int(settings.heatLimit)) °C"
        batteryValue.stringValue = "\(settings.batteryLimit) %"
        heatSlider.isEnabled = settings.heatGuard && thermal.isAvailable
        batterySlider.isEnabled = settings.batteryGuard
    }

    private func updateChipNow() {
        if let temp = thermal.current() {
            chipNow.stringValue = "Chip temperature now: \(Int(temp.rounded())) °C"
        } else {
            chipNow.stringValue = "Chip temperature sensor isn't available on this Mac."
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let power = PowerManager()
    private let thermal = ThermalMonitor()
    private let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private var awake = false
    /// Why the app closed the eyes on its own, shown in the menu until the user reopens them.
    private var autoCloseReason: String?
    private var safetyTimer: Timer?
    private var sigterm: DispatchSourceSignal?
    private lazy var settingsWindow = SettingsWindowController(thermal: thermal) { [weak self] in
        self?.checkSafety()
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
        if settings.batteryGuard, let pct = batteryPercentOnBattery(), pct <= settings.batteryLimit {
            return "The battery is at \(pct) %, at or below your \(settings.batteryLimit) % limit"
        }
        return nil
    }

    private func checkSafety() {
        // Sample even while asleep-allowed so the average is warm when the eyes open.
        let temp = thermal.sample()
        guard awake, let reason = blockReason(temperature: temp) else { return }
        if power.setAwake(false) {
            awake = false
            autoCloseReason = reason
            refresh()
        }
    }

    private func refresh() {
        statusItem.button?.image = EyeIcon.make(open: awake)
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

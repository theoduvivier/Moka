import AppKit

@main enum ProductTests {
    static func main() throws {
        _ = NSApplication.shared
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1; print("PASS: \(name)") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moka-product-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var battery = SessionBattery(.init(onBattery: true, percentage: 80))
        battery.observe(.init(onBattery: true, percentage: 74))
        check(battery.points == 6, "Battery balance measures the whole Mac's net drop")
        battery.observe(.init(onBattery: false, percentage: 74))
        battery.observe(.init(onBattery: true, percentage: 70))
        check(battery.points == nil, "A session that includes charging never presents a misleading battery balance")
        var increasing = SessionBattery(.init(onBattery: true, percentage: 80))
        increasing.observe(.init(onBattery: true, percentage: 81))
        check(increasing.points == nil, "A rising battery gauge invalidates the comparison")
        var missing = SessionBattery(.init(onBattery: true, percentage: 80))
        missing.observe(.init(onBattery: true, percentage: nil))
        check(missing.points == nil, "Missing battery data is not treated as zero consumption")
        check(SessionBattery(.init(onBattery: false, percentage: 100)).points == nil, "AC-only sessions have no battery estimate")
        let suite = "fr.local.moka.product-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var power = PowerSnapshot(onBattery: true, percentage: 80)
        var clock = 100.0
        var heat = ProcessInfo.ThermalState.nominal
        let model = AppModel(defaults: defaults, readPower: { power }, readThermal: { heat }, hasLid: false, uptime: { clock })
        defer { model.shutdown() }
        model.start(); clock += 2520; power.percentage = 74; model.tick(refresh: true); model.stop()
        check(model.summary == .init(seconds: 2520, batteryPoints: 6), "Manual stop freezes the complete session balance")
        check(model.summary?.text == "Session : 42 min · −6 pts de batterie", "Session balance is readable without a dashboard")
        clock += 600; model.stop(); model.tick(refresh: true)
        check(model.summary?.seconds == 2520, "Repeated Stop and later refreshes cannot overwrite a finished session")
        model.start()
        check(model.summary == nil && model.batteryPoints == 0, "New sessions begin with a fresh balance")
        power.percentage = 15; model.tick(refresh: true)
        check(model.stopReason == .battery(15) && model.headline == "Batterie faible" && model.explanation.contains("15 %"), "Battery cutoff explains its cause in the main state")
        power = .init(onBattery: false, percentage: 15); model.tick(refresh: true)
        check(!model.enabled && model.stopReason == .battery(15), "Connecting a charger preserves the stop reason and does not restart")
        model.start(); heat = .serious; model.tick(refresh: true)
        check(model.stopReason == .thermal && model.headline == "Mac trop chaud", "Thermal stop explains its cause in the main state")
        heat = .nominal; model.uninstalling = true; model.start()
        check(!model.enabled, "A session cannot start during uninstallation")
        let lockPath = root.appendingPathComponent("locks")
        var shared: SessionLock? = try SessionLock(exclusive: false, directory: lockPath)
        let second = try SessionLock(exclusive: false, directory: lockPath)
        do { _ = try SessionLock(exclusive: true, directory: lockPath); check(false, "Exclusive lock while busy") }
        catch { check(true, "Uninstall refuses while a Terminal task holds a shared lock") }
        shared = nil
        withExtendedLifetime(second) { check(shared == nil, "Concurrent Terminal tasks may coexist") }
        let exclusivePath = root.appendingPathComponent("exclusive")
        var exclusive: SessionLock? = try SessionLock(exclusive: true, directory: exclusivePath)
        do { _ = try SessionLock(exclusive: false, directory: exclusivePath); check(false, "Task starts during removal") }
        catch { check(true, "New Terminal tasks refuse to start while uninstall owns the lock") }
        exclusive = nil
        _ = try SessionLock(exclusive: false, directory: exclusivePath)
        check(exclusive == nil, "Uninstall cancellation releases its lock")
        let home = root.appendingPathComponent("home")
        let paths = UninstallPlan.dataURLs(home: home).map(\.path)
        check(paths.allSatisfy { $0.hasPrefix(home.path + "/Library/") }, "Uninstaller only targets its own Library data")
        check(paths.count == Set(paths).count && !paths.contains { $0.contains("Keychains") || $0.contains("Documents") }, "Uninstaller preserves sources, documents and signing keys")
        func makeApp(name: String, identifier: String) throws -> URL {
            let app = root.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        try UninstallPlan.validateApplication(makeApp(name: "Moka's test", identifier: "fr.local.moka"))
        check(true, "Uninstaller accepts its own bundle even with spaces and apostrophes")
        do { try UninstallPlan.validateApplication(makeApp(name: "Unrelated", identifier: "fr.example.other")); check(false, "Foreign app removed") }
        catch { check(true, "Uninstaller refuses an unrelated application") }
        print("\(count) product tests passed")
    }
}

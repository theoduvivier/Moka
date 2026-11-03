import Foundation
import IOKit
import OSLog

enum SystemSleep {
    private static let logger = Logger(subsystem: "fr.local.moka", category: "SystemSleep")

    static func read() -> Bool? {
        read(pmset: { command(["-g"]) }, registry: registryValue)
    }

    /// Keep the configured value when pmset can read it. A failed command or an
    /// omitted key is not proof that sleep is enabled: consult the kernel's
    /// explicit SleepDisabled property instead. Never guess from a missing key.
    static func read(pmset: () -> String?, registry: () -> CFTypeRef?) -> Bool? {
        if let output = pmset(), let value = parse(output) { return value }
        guard let raw = registry(), CFGetTypeID(raw) == CFBooleanGetTypeID(),
              let value = raw as? Bool else {
            logger.error("Sleep state unavailable from both pmset and IOPMrootDomain")
            return nil
        }
        logger.notice("Read SleepDisabled from IOPMrootDomain after pmset was unavailable")
        return value
    }

    static func parse(_ output: String) -> Bool? {
        let words = output.split(whereSeparator: { $0.isWhitespace })
        guard let index = words.firstIndex(of: "SleepDisabled"), words.indices.contains(index + 1),
              ["0", "1"].contains(words[index + 1]) else { return nil }
        return words[index + 1] == "1"
    }

    static func registryValue() -> CFTypeRef? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString,
                                              kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    /// The only mutable system setting exposed by the helper.
    static func write(_ disabled: Bool) -> Bool {
        command(["-a", "disablesleep", disabled ? "1" : "0"]) != nil
    }
    private static func command(_ arguments: [String]) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        // A launch daemon must not depend on the login session's directory or stdin.
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Bound a stuck system command. No shell and no inherited user environment.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            guard process.terminationStatus == 0 else {
                logger.error("pmset failed with exit status \(process.terminationStatus)")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            let failure = error as NSError
            logger.error("pmset launch failed: \(failure.domain, privacy: .public) code \(failure.code)")
            return nil
        }
    }
}

import Foundation

enum SystemSleep {
    static func read() -> Bool? {
        guard let output = command(["-g"]) else { return nil }
        let words = output.split(whereSeparator: { $0.isWhitespace })
        guard let index = words.firstIndex(of: "SleepDisabled"), words.indices.contains(index + 1),
              ["0", "1"].contains(words[index + 1]) else { return nil }
        return words[index + 1] == "1"
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
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Bound a stuck system command. No shell and no inherited user environment.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
        } catch { return nil }
    }
}

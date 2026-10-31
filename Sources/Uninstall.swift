import AppKit

enum AppUninstall {
    static func removeService(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                // Refuse to begin while a Terminal task is protected.
                let lock = try SessionLock(exclusive: true)
                withExtendedLifetime(lock) {}
                if UninstallPlan.needsAdministrator {
                    let resource = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/uninstall-helper.sh")
                    let script = try String(contentsOf: resource, encoding: .utf8)
                    let command = "/bin/zsh -f -c " + ShellEscaping.quote(script)
                    let prompt = "Moka doit retirer son service capot. La veille sera restaurée avant sa suppression."
                    let process = Process(), errors = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", "do shell script \(ShellEscaping.appleScriptString(command)) with administrator privileges with prompt \(ShellEscaping.appleScriptString(prompt))"]
                    process.standardOutput = FileHandle.nullDevice; process.standardError = errors
                    try process.run()
                    let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        failure = detail.contains("-128") ? "Désinstallation annulée. Moka est conservé."
                            : "Le service n’a pas pu être retiré. Moka est conservé. " + String(detail.prefix(240))
                    }
                }
                if failure == nil, UninstallPlan.needsAdministrator {
                    failure = "Des fichiers du service sont encore présents. Moka est conservé pour permettre une nouvelle tentative."
                }
            } catch { failure = error.localizedDescription }
            let result = failure
            DispatchQueue.main.async { completion(result) }
        }
    }
    static func finish(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MokaUninstaller")
            process.arguments = ["--parent", String(getpid())]
            process.standardOutput = output; process.standardError = errors
            do {
                try process.run()
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 10_000) > 0 else {
                    process.terminate()
                    throw UninstallPlan.failure("L’assistant de désinstallation ne répond pas. Moka est conservé.")
                }
                let response = output.fileHandleForReading.availableData
                guard String(data: response, encoding: .utf8) == "READY\n" else {
                    let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    throw UninstallPlan.failure(detail.isEmpty ? "L’assistant de désinstallation n’a pas démarré." : detail)
                }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { completion(message) }
            }
        }
    }
}

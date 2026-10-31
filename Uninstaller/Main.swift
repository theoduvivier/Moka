import AppKit
import Darwin

@main enum MokaUninstaller {
    static func main() {
        // Fixed bundle-relative target, no arbitrary path or command arguments.
        let args = CommandLine.arguments
        let app = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard getuid() != 0, args.count == 3, args[1] == "--parent",
              let parentPID = Int32(args[2]), parentPID > 1, getppid() == parentPID,
              let parent = NSRunningApplication(processIdentifier: parentPID),
              parent.bundleIdentifier == "fr.local.moka",
              parent.bundleURL?.resolvingSymlinksInPath() == app else { exit(64) }
        var readySent = false
        do {
            try UninstallPlan.validateApplication(app)
            guard !UninstallPlan.needsAdministrator else {
                throw UninstallPlan.failure("Le service capot doit être retiré avant de supprimer l’application.")
            }
            let lock = try SessionLock(exclusive: true)
            FileHandle.standardOutput.write(Data("READY\n".utf8))
            readySent = true
            try? FileHandle.standardOutput.close()
            // The parent waits for READY before terminating; no user data is
            // removed while Moka may still write preferences or renew a lease.
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            // NSRunningApplication.isTerminated is refreshed by AppKit's run
            // loop. This worker deliberately has no UI run loop. The kernel
            // reparents us as soon as our verified direct parent exits, even
            // if that process has not yet been reaped by its own parent.
            while getppid() == parentPID && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard getppid() != parentPID else {
                throw UninstallPlan.failure("Moka ne s’est pas fermé. Aucun fichier utilisateur n’a été retiré.")
            }
            for domain in UninstallPlan.domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
            UserDefaults.standard.synchronize()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let data = UninstallPlan.dataURLs(home: home)
            // Keep the lock directory until the app has gone. A concurrent CLI
            // launch must see the locked inode instead of creating another one.
            let lockDirectory = SessionLock.directory.standardizedFileURL
            for url in data where url.standardizedFileURL != lockDirectory { try UninstallPlan.trash(url) }
            for root in UninstallPlan.temporaryRoots() {
                for name in UninstallPlan.temporaryNames {
                    try UninstallPlan.trash(root.appendingPathComponent(name), allowProtectedContainer: true)
                }
            }
            try UninstallPlan.trash(app)
            try UninstallPlan.trash(lockDirectory)
            withExtendedLifetime(lock) {}
        } catch {
            if readySent {
                let application = NSApplication.shared
                application.setActivationPolicy(.accessory)
                application.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Désinstallation incomplète"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Fermer")
                alert.runModal()
            } else {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            }
            exit(1)
        }
    }
}

import Foundation
import Darwin

/// CLI sessions hold a shared lock; uninstall holds an exclusive lock. No task
/// is killed by uninstall and a new task cannot enter during removal.
final class SessionLock {
    private var descriptor: Int32 = -1
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fr.local.moka", isDirectory: true)
    }
    init(exclusive: Bool, directory: URL = SessionLock.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Self.failure("Le verrou de session Moka est inaccessible.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw Self.failure("Le verrou de session Moka n’est pas valide.")
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd)
            throw Self.failure(exclusive ? "Une commande utilise encore Moka dans le Terminal. Attendez sa fin, puis réessayez."
                               : "Moka est en cours de désinstallation. Réessayez une fois celle-ci terminée.")
        }
        descriptor = fd
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "fr.local.moka.lock", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}

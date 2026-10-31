import Foundation
import Darwin

enum UninstallPlan {
    static let domains = ["fr.local.moka", "fr.local.moka.updater"]
    static let systemPaths = [
        "/Library/PrivilegedHelperTools/fr.local.moka.helper",
        "/Library/LaunchDaemons/fr.local.moka.helper.plist",
        "/Library/Application Support/Moka",
        "/private/var/run/fr.local.moka-lid.result"
    ]
    static var needsAdministrator: Bool { systemPaths.contains { exists($0) } }
    static func exists(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 }
    static func dataURLs(home: URL) -> [URL] {
        let directories = ["Caches", "HTTPStorages", "WebKit", "Application Support", "Saved Application State"]
        var result = domains.flatMap { domain in directories.map { directory in
            home.appendingPathComponent("Library/\(directory)/\(domain)\(directory == "Saved Application State" ? ".savedState" : "")")
        } }
        // Preferences are removed last, after cfprefsd has cleared its cached values.
        result += domains.map { home.appendingPathComponent("Library/Preferences/\($0).plist") }
        return result
    }
    static let temporaryNames = ["fr.local.moka", "fr.local.moka.updater",
        "com.apple.WebKit.Networking+fr.local.moka.updater",
        "com.apple.WebKit.WebContent+fr.local.moka.updater", "com.apple.WebKit.GPU+fr.local.moka.updater"]
    static func temporaryRoots() -> [URL] {
        [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap { key in
            let length = confstr(key, nil, 0)
            guard length > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: length)
            guard confstr(key, &buffer, length) > 0 else { return nil }
            return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        }
    }
    static func validateApplication(_ url: URL) throws {
        guard url.pathExtension == "app", !url.path.hasPrefix("/System/"),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == "fr.local.moka" else {
            throw failure("La copie de Moka à retirer n’a pas pu être identifiée.")
        }
    }
    /// Trash symlinks themselves, never their targets. Some WebKit temporary
    /// directories have SF_NOUNLINK: clear their contents and leave the empty
    /// OS-owned container. Do not request extra privileges to change OS flags.
    static func trash(_ url: URL, allowProtectedContainer: Bool = false) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw failure("Impossible de lire \(url.lastPathComponent).")
        }
        if allowProtectedContainer, info.st_mode & S_IFMT == S_IFDIR,
           info.st_flags & UInt32(SF_NOUNLINK) != 0 {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try trash(child, allowProtectedContainer: true)
            }
            return
        }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    static func failure(_ description: String) -> NSError {
        NSError(domain: "fr.local.moka.uninstall", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

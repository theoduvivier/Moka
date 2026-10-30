import Foundation

enum HelperConstants {
    static let label = "fr.local.moka.helper"
    static let executable = "/Library/PrivilegedHelperTools/fr.local.moka.helper"
    static let directory = "/Library/Application Support/Moka"
    static let configuration = directory + "/helper.plist"
    static let journal = directory + "/session.plist"
    static let launchPlist = "/Library/LaunchDaemons/fr.local.moka.helper.plist"
    static let protocolVersion = 1
    static let leaseSeconds: TimeInterval = 25
    static let sessionSeconds: TimeInterval = 4 * 60 * 60
}

/// Deliberately no command, executable, path, PID or shell-string parameters.
@objc protocol MokaHelperProtocol {
    func beginSession(reserve: Int, reply: @escaping (NSDictionary) -> Void)
    func renewSession(reserve: Int, reply: @escaping (NSDictionary) -> Void)
    func endSession(reply: @escaping (NSDictionary) -> Void)
    func status(reply: @escaping (NSDictionary) -> Void)
}

struct HelperStatus {
    var active = false
    var previousDisabled = false
    var restorationFailed = false
    var message = ""
    var dictionary: NSDictionary {
        ["version": HelperConstants.protocolVersion, "active": active,
         "previousDisabled": previousDisabled, "restorationFailed": restorationFailed, "message": message]
    }
    init(active: Bool = false, previousDisabled: Bool = false, restorationFailed: Bool = false, message: String = "") {
        self.active = active; self.previousDisabled = previousDisabled
        self.restorationFailed = restorationFailed; self.message = message
    }
    init?(dictionary: NSDictionary) {
        guard dictionary["version"] as? Int == HelperConstants.protocolVersion,
              let active = dictionary["active"] as? Bool,
              let previous = dictionary["previousDisabled"] as? Bool,
              let failed = dictionary["restorationFailed"] as? Bool,
              let message = dictionary["message"] as? String else { return nil }
        self.init(active: active, previousDisabled: previous, restorationFailed: failed, message: message)
    }
}

import Foundation
import Security

enum CodeIdentity {
    static func requirement(at url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess else {
            throw identityError("La signature de Moka est invalide. Réinstallez l’application.")
        }
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement, SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else { throw identityError("Signature de Moka introuvable.") }
        return text as String
    }
    static func matches(_ url: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess, let rule else { return false }
        // The designated requirement may pin the current architecture's cdhash.
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess
    }
    private static func identityError(_ description: String) -> NSError {
        NSError(domain: "fr.local.moka.signature", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

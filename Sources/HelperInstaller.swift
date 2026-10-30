import Foundation
import Darwin

enum HelperInstaller {
    static var bundledHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/MokaHelper") }
    static func prepare(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                let client = try CodeIdentity.requirement(at: Bundle.main.bundleURL)
                let helper = try CodeIdentity.requirement(at: bundledHelper)
                if !installed(client: client, helper: helper) {
                    let script = try installScript(source: bundledHelper.path, client: client, helper: helper, uid: getuid())
                    let command = "/bin/sh -p -c " + ShellEscaping.quote(script)
                    let prompt = "Installez le service Moka une fois. Le mode capot pourra ensuite être activé sans mot de passe."
                    let appleScript = "do shell script \(ShellEscaping.appleScriptString(command)) with administrator privileges with prompt \(ShellEscaping.appleScriptString(prompt))"
                    let process = Process(), errors = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", appleScript]
                    process.standardOutput = FileHandle.nullDevice; process.standardError = errors
                    try process.run()
                    let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        if detail.contains("-128") { failure = "Installation annulée. Le mode capot reste désactivé." }
                        else if detail.contains("MOKA_RESTORE_PENDING") { failure = "La restauration de la session précédente doit se terminer avant l’installation." }
                        else { failure = "Le service Moka n’a pas pu être installé. " + String(detail.prefix(240)) }
                    } else if !installed(client: client, helper: helper) {
                        failure = "macOS n’a pas confirmé l’installation du service Moka."
                    }
                }
            } catch { failure = error.localizedDescription }
            let result = failure
            DispatchQueue.main.async { completion(result) }
        }
    }
    static func installed(client: String, helper: String) -> Bool {
        func protected(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0 && info.st_mode & S_IFMT == S_IFREG
        }
        guard protected(HelperConstants.configuration), protected(HelperConstants.executable), protected(HelperConstants.launchPlist),
              let data = FileManager.default.contents(atPath: HelperConstants.configuration),
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              config["uid"] as? UInt32 == getuid(), config["clientRequirement"] as? String == client,
              config["helperRequirement"] as? String == helper,
              let bundled = try? Data(contentsOf: bundledHelper),
              let installed = FileManager.default.contents(atPath: HelperConstants.executable), bundled == installed else { return false }
        return CodeIdentity.matches(URL(fileURLWithPath: HelperConstants.executable), requirement: helper)
    }
    static func installScript(source: String, client: String, helper: String, uid: uid_t) throws -> String {
        let config: [String: Any] = ["uid": uid, "clientRequirement": client, "helperRequirement": helper]
        let launch: [String: Any] = ["Label": HelperConstants.label, "ProgramArguments": [HelperConstants.executable],
            "MachServices": [HelperConstants.label: true], "RunAtLoad": true, "KeepAlive": true,
            "ThrottleInterval": 10, "ExitTimeOut": 15, "ProcessType": "Background", "Umask": 0o077]
        let config64 = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).base64EncodedString()
        let launch64 = try PropertyListSerialization.data(fromPropertyList: launch, format: .xml, options: 0).base64EncodedString()
        let q = ShellEscaping.quote
        return """
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        umask 077
        [ "$(/usr/bin/id -u)" = 0 ] || exit 77
        protected_dir() {
          [ ! -L "$1" ] && [ -d "$1" ] || exit 78
          [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || exit 78
          permissions=$(/usr/bin/stat -f %Lp "$1")
          [ "$((0$permissions & 0022))" = 0 ] || exit 78
        }
        protected_dir /Library
        protected_dir '/Library/Application Support'
        for directory in /Library/PrivilegedHelperTools /Library/LaunchDaemons \(q(HelperConstants.directory)); do
          [ -e "$directory" ] || /bin/mkdir -m 755 "$directory"
          protected_dir "$directory"
        done
        for file in \(q(HelperConstants.executable)) \(q(HelperConstants.configuration)) \(q(HelperConstants.launchPlist)) \(q(HelperConstants.journal)); do
          [ ! -L "$file" ] || exit 78
          if [ -e "$file" ]; then
            [ -f "$file" ] && [ "$(/usr/bin/stat -f %u "$file")" = 0 ] || exit 78
            permissions=$(/usr/bin/stat -f %Lp "$file")
            [ "$((0$permissions & 0022))" = 0 ] || exit 78
          fi
        done
        staging=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.moka.XXXXXX)
        trap '/bin/rm -rf "$staging"' EXIT
        /bin/cp \(q(source)) "$staging/helper"
        /usr/sbin/chown 0:0 "$staging/helper"
        /bin/chmod 755 "$staging/helper"
        # Verify the protected copy before any privileged execution.
        /usr/bin/codesign --verify --strict -R \(q(helper)) "$staging/helper"
        /usr/bin/printf %s \(q(config64)) | /usr/bin/base64 -D > "$staging/config"
        /usr/bin/printf %s \(q(launch64)) | /usr/bin/base64 -D > "$staging/launch"
        /usr/bin/plutil -lint "$staging/config" "$staging/launch" >/dev/null
        if /bin/launchctl print system/\(HelperConstants.label) >/dev/null 2>&1; then
          /bin/launchctl bootout system/\(HelperConstants.label)
        fi
        attempt=0
        while [ -e \(q(HelperConstants.journal)) ] && [ "$attempt" -lt 15 ]; do
          /bin/sleep 1
          attempt=$((attempt + 1))
        done
        if [ -e \(q(HelperConstants.journal)) ]; then
          # Leave the old service able to retry restoration if its stop failed.
          /bin/launchctl bootstrap system \(q(HelperConstants.launchPlist)) 2>/dev/null || true
          /usr/bin/printf MOKA_RESTORE_PENDING >&2
          exit 79
        fi
        /bin/chmod 644 "$staging/config" "$staging/launch"
        /bin/mv -f "$staging/helper" \(q(HelperConstants.executable))
        /bin/mv -f "$staging/config" \(q(HelperConstants.configuration))
        /bin/mv -f "$staging/launch" \(q(HelperConstants.launchPlist))
        /bin/launchctl enable system/\(HelperConstants.label)
        /bin/launchctl bootstrap system \(q(HelperConstants.launchPlist))
        """
    }
}

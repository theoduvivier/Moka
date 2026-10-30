import Foundation
@main enum InstallerTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) { precondition(condition, name); count += 1; print("PASS: \(name)") }
        let path = "/tmp/Moka's app/$(touch NEVER)/MokaHelper"
        let rule = "cdhash H\"0000000000000000000000000000000000000000\""
        let script = try HelperInstaller.installScript(source: path, client: rule, helper: rule, uid: 501)
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]; process.standardInput = input
        try process.run(); input.fileHandleForWriting.write(Data(script.utf8)); try input.fileHandleForWriting.close(); process.waitUntilExit()
        check(process.terminationStatus == 0, "Installer shell syntax remains valid with apostrophes and metacharacters")
        let expression = try NSRegularExpression(pattern: "printf %s '([A-Za-z0-9+/=]+)' ")
        let values = try expression.matches(in: script, range: NSRange(script.startIndex..., in: script)).map { match -> [String: Any] in
            let encoded = String(script[Range(match.range(at: 1), in: script)!])
            return try PropertyListSerialization.propertyList(from: Data(base64Encoded: encoded)!, format: nil) as! [String: Any]
        }
        check(values.count == 2 && values[0]["uid"] as? UInt32 == 501 && values[0]["clientRequirement"] as? String == rule,
              "Root configuration binds the authorizing UID and exact client identity")
        check(values[1]["ProgramArguments"] as? [String] == [HelperConstants.executable], "Launch daemon accepts no user-supplied command arguments")
        check(values[1]["MachServices"] as? [String: Bool] == [HelperConstants.label: true], "Daemon exposes only its fixed Mach service")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let realRule = try CodeIdentity.requirement(at: executable)
        func verify(_ requirement: String) throws -> Bool {
            let generated = try HelperInstaller.installScript(source: executable.path, client: realRule, helper: requirement, uid: getuid())
            let line = generated.components(separatedBy: .newlines).first { $0.hasPrefix("/usr/bin/codesign ") }!
            let command = line.replacingOccurrences(of: "\"$staging/helper\"", with: ShellEscaping.quote(executable.path))
            let verifier = Process()
            verifier.executableURL = URL(fileURLWithPath: "/bin/sh")
            verifier.arguments = ["-c", command]
            verifier.standardError = FileHandle.nullDevice
            try verifier.run(); verifier.waitUntilExit()
            return verifier.terminationStatus == 0
        }
        check(try verify(realRule), "Exact installer codesign command accepts the pinned signed binary")
        check(try !verify("identifier \"fr.local.moka.wrong-helper\""), "Exact installer codesign command rejects another identity")
        print("\(count) installer tests passed")
    }
}

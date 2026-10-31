"""Exercise the actual uninstaller lifecycle with an isolated app and fixture data.
Only the fixed destinations/domains are redirected in temporary source copies.
Never touches the installed app, its preferences, root helper, or signing keys.
"""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import uuid

repo = Path(__file__).resolve().parents[1]
checks = 0

def check(value, message):
    global checks
    assert value, message
    checks += 1
    print('PASS: ' + message, flush=True)

def swift_string(path):
    # These fixture paths are generated locally; JSON string syntax is also
    # Swift string syntax for the ASCII path characters used here.
    import json
    return json.dumps(str(path))

with tempfile.TemporaryDirectory(prefix='moka-uninstall-lifecycle-', dir='/private/tmp') as tmp:
    root = Path(tmp)
    domain = 'fr.local.moka.uninstall-tests.' + uuid.uuid4().hex
    home = root/'Home'
    temporary = root/'Temporary'
    lock = home/'Library/Caches'/domain
    app = root/'Moka Test.app'
    for folder in [app/'Contents/MacOS', app/'Contents/Helpers', home/'Documents', temporary]:
        folder.mkdir(parents=True, exist_ok=True)
    (home/'Documents/preserve.txt').write_text('user sources')
    prefs = home/'Library/Preferences'/f'{domain}.plist'
    prefs.parent.mkdir(parents=True)
    prefs.write_bytes(plistlib.dumps({'fixture': True}))
    cache = home/'Library/Caches'/domain
    cache.mkdir(parents=True)
    (cache/'test.txt').write_text('cache')
    temp = temporary/domain
    temp.mkdir()
    (temp/'test.txt').write_text('temporary')

    source = (repo/'Shared/UninstallPlan.swift').read_text()
    source, count = re.subn(r'static let systemPaths = \[.*?\n    \]', 'static let systemPaths: [String] = []', source, flags=re.S)
    assert count == 1
    source = source.replace('fr.local.moka', domain)
    source = source.replace('bundle.bundleIdentifier == "'+domain+'"', 'bundle.bundleIdentifier == "fr.local.moka"')
    source = source.replace('static func dataURLs(home: URL) -> [URL] {', 'static func dataURLs(home ignored: URL) -> [URL] {\n        let home = URL(fileURLWithPath: '+swift_string(home)+')')
    source = source.replace('return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)', 'return URL(fileURLWithPath: '+swift_string(temporary)+', isDirectory: true)')
    (root/'UninstallPlan.swift').write_text(source)
    lock_source = (repo/'Shared/SessionLock.swift').read_text()
    lock_source, count = re.subn(r'FileManager.default.urls\(for: .cachesDirectory, in: .userDomainMask\)\[0\]\s*.appendingPathComponent\("fr.local.moka", isDirectory: true\)', 'URL(fileURLWithPath: '+swift_string(lock)+', isDirectory: true)', lock_source)
    assert count == 1
    (root/'SessionLock.swift').write_text(lock_source)
    # Worker code is unmodified; only its test-linked destinations differ.
    worker = app/'Contents/Helpers/MokaUninstaller'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(repo/'Uninstaller/Main.swift'), str(root/'UninstallPlan.swift'), str(root/'SessionLock.swift'), '-o', str(worker), '-framework', 'AppKit'], check=True)
    parent_source = root/'Parent.swift'
    parent_source.write_text('''import AppKit
@main enum TestParent {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let child = Process(), output = Pipe()
            child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MokaUninstaller")
            child.arguments = ["--parent", String(getpid())]
            child.standardOutput = output
            do { try child.run() } catch { exit(70) }
            DispatchQueue.global().async {
                let response = output.fileHandleForReading.availableData
                guard String(data: response, encoding: .utf8) == "READY\\n" else { exit(71) }
                DispatchQueue.main.async { app.terminate(nil) }
            }
        }
        app.run()
    }
}''')
    parent = app/'Contents/MacOS/Fixture'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(parent_source), '-o', str(parent), '-framework', 'AppKit'], check=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'fr.local.moka', 'CFBundleExecutable': 'Fixture', 'CFBundlePackageType': 'APPL', 'LSUIElement': True}))
    result = subprocess.run([str(parent)], capture_output=True, timeout=25)
    check(result.returncode == 0, 'The real uninstaller acknowledges its parent and allows a clean quit')
    for _ in range(100):
        if not app.exists(): break
        time.sleep(.1)
    check(not app.exists(), 'The worker moves only its own test application to Trash after the parent exits')
    check(not prefs.exists() and not cache.exists() and not temp.exists(), 'The worker removes the fixture preferences, caches and temporary data')
    check((home/'Documents/preserve.txt').read_text() == 'user sources', 'Development files survive the complete uninstaller lifecycle')
print(f'{checks} uninstaller lifecycle tests passed')

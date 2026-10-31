"""Exercise the shipped shell script against a fake Library and launchd.
No root privileges, pmset writes, or real launchd changes.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SOURCE = (Path(__file__).resolve().parents[1] / 'Tools/uninstall-helper.sh').read_text()
checks = 0

def check(ok, text):
    global checks
    assert ok, text
    checks += 1
    print('PASS: ' + text)

with tempfile.TemporaryDirectory(prefix='moka-uninstall-tests-', dir='/private/tmp') as tmp:
    base = Path(tmp)
    library = base / 'Library'
    data = library / 'Application Support/Moka'
    plist = library / 'LaunchDaemons/fr.local.moka.helper.plist'
    binary = library / 'PrivilegedHelperTools/fr.local.moka.helper'
    journal = data / 'session.plist'
    loaded = base / 'loaded'
    events = base / 'events'
    stat = base / 'stat'
    stat.write_text('#!/bin/zsh\nif [[ "$2" == %u ]]; then print 0; else /usr/bin/stat "$@"; fi\n')
    stat.chmod(0o755)
    launchctl = base / 'launchctl'
    launchctl.write_text(f'''#!{sys.executable}
import os, pathlib, sys
base = pathlib.Path({str(base)!r})
loaded, journal = base/'loaded', base/'Library/Application Support/Moka/session.plist'
op = sys.argv[1]
with (base/'events').open('a') as f: f.write(op+'\\n')
if op == 'print': sys.exit(0 if loaded.exists() else 1)
if op == 'bootstrap': loaded.touch()
if op == 'bootout': loaded.unlink(missing_ok=True)
if os.environ.get('RESTORE_OK') == '1': journal.unlink(missing_ok=True)
''')
    launchctl.chmod(0o755)
    guard = "[[ $EUID == 0 ]] || { print -u2 'Quittez Moka, puis exécutez : sudo zsh Tools/uninstall-helper.sh'; exit 1; }"
    assert SOURCE.count(guard) == 1
    script = SOURCE.replace(guard, ': # Root boundary simulated only in this fixture')
    script = script.replace('/Library', str(library)).replace('/private/var/run', str(base/'run'))
    script = script.replace('/bin/launchctl', str(launchctl)).replace('/usr/bin/stat', str(stat)).replace('/bin/sleep 1', '/usr/bin/true')
    def prepare(with_journal=True, running=True):
        shutil.rmtree(library, ignore_errors=True)
        for path in [data, plist.parent, binary.parent, base/'run']:
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(0o755)
        for path in [plist, binary, data/'helper.plist']: path.write_text('fixture')
        if with_journal: journal.write_text('must restore')
        loaded.unlink(missing_ok=True)
        if running: loaded.touch()
        events.write_text('')
        (base/'unrelated').write_text('preserve')
    def run(restore=True):
        return subprocess.run(['/bin/zsh', '-f', '-c', script], capture_output=True, text=True,
                              env={**os.environ, 'RESTORE_OK': '1' if restore else '0'})
    prepare()
    result = run()
    if result.returncode: print(result.stderr, result.stdout)
    check(result.returncode == 0 and not binary.exists() and not plist.exists() and not data.exists(),
          'Uninstall waits for successful restoration before removing its service')
    check((base/'unrelated').read_text() == 'preserve', 'Uninstall preserves unrelated data')
    prepare()
    result = run(False)
    check(result.returncode != 0 and journal.exists() and binary.exists() and plist.exists(),
          'A failed restoration keeps the journal and all service files')
    check(loaded.exists() and 'bootstrap' in events.read_text(), 'Failed shutdown restarts the recovery service')
    prepare(running=False)
    result = run()
    check(result.returncode == 0 and events.read_text().index('bootstrap') < events.read_text().index('bootout'),
          'An unloaded service is allowed to recover before shutdown')
    prepare(running=False)
    result = run(False)
    check(result.returncode != 0 and journal.exists() and 'bootout' not in events.read_text(),
          'An unrecovered service is never stopped or removed')
    prepare(with_journal=False, running=False)
    check(run().returncode == 0, 'An already stopped service without a journal can be removed')
    prepare()
    data.chmod(0o777)
    check(run().returncode != 0 and not events.read_text(), 'Writable system parents are rejected before launchd is touched')
    prepare()
    original = data.with_name('original')
    data.rename(original)
    data.symlink_to(original, target_is_directory=True)
    check(run().returncode != 0 and (original/'session.plist').exists(), 'Symlinked system directories are refused')
    data.unlink()
    prepare()
    journal.unlink()
    journal.symlink_to(base/'unrelated')
    check(run().returncode != 0 and (base/'unrelated').read_text() == 'preserve', 'Symlinked journals are never followed')
print(f'{checks} uninstall-script tests passed')

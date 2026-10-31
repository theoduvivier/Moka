"""Run against a built Moka.app. Creates only short, ordinary wake assertions."""
from pathlib import Path
import os
import signal
import subprocess
import sys
import time

app = Path(sys.argv[1]).resolve()
cli = app / 'Contents/MacOS/moka-cli'
checks = 0

def check(ok, text):
    global checks
    assert ok, text
    checks += 1
    print('PASS: ' + text, flush=True)

def run(*args, input=None):
    return subprocess.run([str(cli), *args], input=input, text=True, capture_output=True, timeout=15)

def watchers(parent):
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True).splitlines()
    suffix = f'{cli} --watch {parent} '
    return [int(row.split(None, 1)[0]) for row in rows if suffix in row]

def eventually(predicate):
    for _ in range(50):
        if predicate(): return True
        time.sleep(.1)
    return False

result = run('--help')
check(result.returncode == 0 and 'moka run' in result.stdout, 'Terminal help describes its scope')
result = run('run', '--reserve', '4', '/bin/echo', 'must not run')
check(result.returncode == 64 and not result.stdout, 'Invalid battery thresholds cannot launch a command')
result = run('run', '/usr/bin/printf', '%s\n', 'argument avec espaces', '$(ne-pas-executer)', "l'apostrophe")
check(result.returncode == 0 and result.stdout == "argument avec espaces\n$(ne-pas-executer)\nl'apostrophe\n", 'Arguments remain literal without shell interpolation')
check('Attempting to use' not in result.stderr, 'Preferences are read without a UserDefaults bundle warning')
result = run('run', '/bin/cat', input='entrée standard\nligne 2\n')
check(result.returncode == 0 and result.stdout == 'entrée standard\nligne 2\n', 'Piped stdin and stdout pass through unchanged')
result = run('run', '/bin/sh', '-c', 'printf diagnostic >&2; exit 7')
check(result.returncode == 7 and 'diagnostic' in result.stderr, 'Command exit codes and stderr are preserved')
result = run('run', 'moka-command-that-does-not-exist')
check(result.returncode == 127, 'A missing executable returns the normal command-not-found status')
result = run('run', '--reserve', '5', '--', '/bin/echo', '--reserve')
check(result.returncode == 0 and result.stdout == '--reserve\n' and '5 %' in result.stderr, 'Explicit thresholds and the argument separator work')

process = subprocess.Popen([str(cli), 'run', '/bin/sleep', '30'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    check(eventually(lambda: bool(watchers(process.pid))), 'A live command has a dedicated watcher')
    ids = watchers(process.pid)
    process.stderr.readline()  # Startup message is emitted after assertion creation.
    assertions = subprocess.check_output(['/usr/bin/pmset', '-g', 'assertions'], text=True, errors='replace')
    lines = [line for line in assertions.splitlines() if any(f'pid {pid}(' in line for pid in ids)]
    check(any('PreventUserIdleSystemSleep' in line and 'commande Terminal' in line for line in lines), 'A running command owns a real system-idle wake assertion')
    check(not any('PreventUserIdleDisplaySleep' in line for line in lines), 'Terminal sessions allow the display to sleep')
    process.send_signal(signal.SIGTERM)
    process.communicate(timeout=10)
    check(process.returncode == -signal.SIGTERM, 'Signals reach the actual command with their normal exit status')
    check(eventually(lambda: not watchers(process.pid)), 'The watcher exits after command termination')
    assertions = subprocess.check_output(['/usr/bin/pmset', '-g', 'assertions'], text=True, errors='replace')
    check(not any(f'pid {pid}(' in assertions for pid in ids), 'Command termination releases its wake assertion')
finally:
    if process.poll() is None: process.kill(); process.communicate(timeout=10)
result = subprocess.run([str(app/'Contents/Helpers/MokaUninstaller'), '--parent', str(os.getpid())], capture_output=True, timeout=10)
check(result.returncode == 64, 'The uninstaller refuses to run outside its own application')
print(f'{checks} CLI integration tests passed')

"""Run the actual watchdog script against fake pmset. No root or real settings."""
from pathlib import Path
import os
import re
import subprocess
import time
import tempfile

root = Path(__file__).resolve().parents[1] / "build" / "guard-tests"
template = (root / "guard-template.sh").read_text()
count = 0

def check_case(name, original=0, trigger="remove", failure=None, reason="stopped"):
    global count
    with tempfile.TemporaryDirectory(prefix="case-", dir=root) as folder:
        folder = Path(folder)
        state, calls, beat, control, lock = [folder / n for n in ("state", "calls", "heartbeat", "control", "lock")]
        state.write_text(str(original)); beat.touch(); control.write_text("ac")
        fake = folder / "pmset"
        fake.write_text(f'''#!/bin/sh
if [ "$1" = "-g" ]; then
  if [ "$2" = "batt" ]; then
    case "$(/bin/cat '{control}')" in
      battery20) /usr/bin/printf "Now drawing from 'Battery Power'\\n -InternalBattery-0 20%%; discharging\\n" ;;
      battery) /usr/bin/printf "Now drawing from 'Battery Power'\\n -InternalBattery-0 10%%; discharging\\n" ;;
      unknown) /usr/bin/printf "Now drawing from 'Battery Power'\\n" ;;
      *) /usr/bin/printf "Now drawing from 'AC Power'\\n -InternalBattery-0 100%%; charged\\n" ;;
    esac
  else
    /usr/bin/printf ' SleepDisabled %s\\n' "$(/bin/cat '{state}')"
  fi
else
  /usr/bin/printf '%s\\n' "$3" >> '{calls}'
  {'[ "$3" != 0 ] || exit 1' if failure == 'restore' else ':'}
  {'[ "$3" != 1 ] || exit 1' if failure == 'activate' else ':'}
  {'[ "$3" != 1 ] || exit 0' if failure == 'lie_activate' else ':'}
  {'[ "$3" != 0 ] || exit 0' if failure == 'lie_restore' else ':'}
  /usr/bin/printf '%s' "$3" > '{state}'
fi
''')
        fake.chmod(0o700)
        script = template.replace("/usr/bin/pmset", str(fake)).replace("/private/var/run/fr.local.moka-lid", str(lock)).replace(str(root / "heartbeat"), str(beat))
        sleeper = subprocess.Popen(["/bin/sleep", "20"])
        script = re.sub(r"/bin/kill -0 \d+", f"/bin/kill -0 {sleeper.pid}", script).replace("/bin/sleep 2", "/bin/sleep 0.1")
        if trigger == "limit": script = script.replace("-lt 14400", "-lt 0")
        if trigger == "initial_stale": os.utime(beat, (time.time()-25, time.time()-25))
        if trigger == "initial_battery": control.write_text("battery")
        if trigger == "initial_unknown": control.write_text("unknown")
        if trigger == "missing": beat.unlink()
        if trigger in ("dead_lock", "busy_lock"):
            lock.mkdir(); (lock / "token").write_text("old-token")
            (lock / "pid").write_text(str(os.getpid()) if trigger == "busy_lock" else "2147483647")
            (lock / "previous").write_text(str(original))
            state.write_text("1")
        process = subprocess.Popen(["/bin/sh", "-c", script], stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if ((lock / "token").exists() and (lock / "token").read_text() == "test-token") or process.poll() is not None: break
                time.sleep(.03)
            if trigger in ("remove", "dead_lock") and beat.exists(): beat.unlink()
            elif trigger == "crash": sleeper.terminate(); sleeper.wait()
            elif trigger == "stale": os.utime(beat, (time.time()-25, time.time()-25))
            elif trigger == "battery": control.write_text("battery")
            elif trigger == "raise_cutoff": beat.write_text("25\n"); control.write_text("battery20")
            elif trigger == "lower_cutoff":
                beat.write_text("5\n"); control.write_text("battery")
                time.sleep(.3)
                assert process.poll() is None, "lowered threshold should keep the guard active"
                beat.unlink()
            elif trigger == "invalid_cutoff": beat.write_text("not a number"); control.write_text("battery")
            elif trigger == "low_cutoff": beat.write_text("0\n"); control.write_text("battery")
            elif trigger == "high_cutoff": beat.write_text("99\n"); control.write_text("battery")
            elif trigger == "unknown": control.write_text("unknown")
            elif trigger == "signal": process.terminate()
            elif trigger == "external": state.write_text("0")
            process.communicate(timeout=5)
            result = Path(str(lock)+".result").read_text().splitlines()
            assert result[0] == "test-token" and result[1] == reason, (name, result)
            changes = calls.read_text().splitlines() if calls.exists() else []
            if failure in ("restore", "lie_restore"):
                assert process.returncode == 75 and lock.exists() and result[3] == "0", name
                assert state.read_text() == "1", name
            elif trigger == "busy_lock":
                assert process.returncode == 73 and lock.exists() and not changes, name
                assert state.read_text() == "1", name
            else:
                expected = "0" if trigger == "external" else str(original)
                assert state.read_text() == expected and not lock.exists(), name
                if trigger in ("initial_stale", "initial_battery", "initial_unknown", "missing"):
                    assert not changes, name + ": never disabled sleep before eligibility"
                elif trigger == "external": assert changes == ["1"], name + ": preserved the external change"
                elif trigger == "dead_lock": assert changes == [str(original), "1", str(original)], name
                else: assert changes == ["1", str(original)], (name, changes)
            count += 1
            print("PASS:", name)
        finally:
            if process.poll() is None: process.kill(); process.wait()
            if sleeper.poll() is None: sleeper.terminate(); sleeper.wait()

check_case("Normal stop restores sleep")
check_case("Application crash restores sleep", trigger="crash", reason="app_exited")
check_case("Unresponsive app restores sleep", trigger="stale", reason="heartbeat")
check_case("Battery cutoff restores sleep", trigger="battery", reason="battery")
check_case("Unreadable battery ends the guard", trigger="unknown", reason="battery_unknown")
check_case("Four-hour cutoff restores sleep", trigger="limit", reason="limit")
check_case("Termination signal restores sleep", trigger="signal", reason="signal")
check_case("Pre-existing disabled sleep is preserved", original=1)
check_case("Restore command failure is reported", failure="restore", reason="restore_failed")
check_case("Restore command's success code is verified", failure="lie_restore", reason="restore_failed")
check_case("Activation command failure is reported", failure="activate", reason="activate_failed")
check_case("Activation command's success code is verified", failure="lie_activate", reason="activate_failed")
check_case("Old heartbeat cannot enable sleep prevention", trigger="initial_stale", reason="heartbeat")
check_case("Low battery cannot enable sleep prevention", trigger="initial_battery", reason="battery")
check_case("Unknown battery cannot enable sleep prevention", trigger="initial_unknown", reason="battery_unknown")
check_case("Late authorization after cancellation changes nothing", trigger="missing")
check_case("External re-enabling of sleep is respected", original=1, trigger="external", reason="system_changed")
check_case("Dead guard's previous setting is restored before a new session", trigger="dead_lock")
check_case("Live guard is never replaced or killed", trigger="busy_lock", reason="busy")
check_case("Changing the live cutoff takes effect", trigger="raise_cutoff", reason="battery")
check_case("Lowering the live cutoff keeps the guard active", trigger="lower_cutoff")
check_case("Malformed cutoff falls back to the safe initial value", trigger="invalid_cutoff", reason="battery")
check_case("A cutoff below 5 is rejected", trigger="low_cutoff", reason="battery")
check_case("A cutoff above 50 is rejected", trigger="high_cutoff", reason="battery")
print(f"{count} watchdog scenarios passed; real power settings were never changed")

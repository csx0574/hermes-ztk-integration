#!/usr/bin/env python3
"""
Unit tests for ztk_integration.maybe_wrap_command

Run from repo root:
    cd tests && python3 test_ztk_integration.py

Expected output:
    14/14 passed
"""
import sys
import os
from pathlib import Path

# Allow running from tests/ directory without install
sys.path.insert(0, str(Path(__file__).parent.parent))

from ztk_integration import maybe_wrap_command, _should_wrap


def assert_wrap(cmd: str, expected_wrap: bool, reason_hint: str = "") -> bool:
    """Helper: assert wrap decision matches expectation."""
    got, reason = _should_wrap(cmd)
    wrapped = maybe_wrap_command(cmd)
    actually_wrapped = wrapped != cmd
    ok = (got == expected_wrap) and (actually_wrapped == expected_wrap)
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] expect={expected_wrap} got={got} | {cmd!r}")
    if reason_hint and reason != reason_hint:
        print(f"        reason hint mismatch: {reason!r} vs {reason_hint!r}")
    if not ok:
        print(f"        actual wrapped output: {wrapped!r}")
    return ok


def main():
    passed = 0
    total = 0

    cases = [
        # === Should WRAP (simple commands, no shell metacharacter) ===
        ("ls -la /tmp/",                              True),
        ("git status",                                True),
        ("cargo test --all",                          True),
        ("echo hello world",                          True),
        ("cat /etc/hostname",                         True),
        ("pwd",                                       True),

        # === Should NOT WRAP (compound/has shell metacharacter) ===
        ("ls -la | head",                             False),
        ("ls -la > /tmp/out.txt",                     False),
        ("cat foo < bar",                             False),
        ("echo $(whoami)",                            False),
        ("echo `date`",                               False),
        ("ls; pwd",                                   False),
        ("cd /tmp && ls",                             False),
        ("git log || true",                           False),

        # === Should NOT WRAP (interactive / builtins / shell wrappers) ===
        ("vim foo.txt",                               False),  # interactive
        ("cd /tmp",                                   False),  # builtin
        ("bash -c \"echo hi\"",                       False),  # shell wrapper
        ("sudo apt install",                          False),  # password prompt
        ("xargs -I {} echo",                          False),  # arg forwarding

        # === Should NOT WRAP (edge cases) ===
        ("",                                          False),  # empty
        ("--help",                                    False),  # dash prefix
        ("\"unclosed quote",                          False),  # malformed

        # === With variable expansion (still detected as risky → skip) ===
        ("echo $HOME",                                False),  # contains $
        ('echo "$HOME"',                              False),  # contains $ in quotes
    ]

    print("=" * 60)
    print(f"Running {len(cases)} test cases")
    print("=" * 60)
    for cmd, expected in cases:
        total += 1
        if assert_wrap(cmd, expected):
            passed += 1

    print()
    print("=" * 60)
    print(f"Result: {passed}/{total} passed")
    print("=" * 60)

    # Bonus: disable switch
    print("\n=== Disable switch test (HERMES_ZTK_DISABLED=1) ===")
    os.environ["HERMES_ZTK_DISABLED"] = "1"
    # _should_wrap 每次调用时读 os.environ，不需要 reload 模块
    total += 1
    out = maybe_wrap_command("ls -la /tmp/")
    if out == "ls -la /tmp/":
        print(f"[PASS] HERMES_ZTK_DISABLED respected")
        passed += 1
    else:
        print(f"[FAIL] wrap still happened: {out!r}")
    del os.environ["HERMES_ZTK_DISABLED"]

    # Bonus: ztk binary not present everywhere → skip wrap
    # Move the real binary temporarily out of the way to simulate "no ztk installed"
    print("\n=== No ztk binary test (simulate ztk not installed) ===")
    # Hide ztk via HERMES_ZTK_BIN pointing to nonexistent, AND override HOME so
    # ~/.local/bin/ztk-safe isn't found. Use a temp HOME directory.
    import tempfile
    fake_home = tempfile.mkdtemp(prefix="hermes_ztk_test_")
    old_home = os.environ.get("HOME")
    os.environ["HOME"] = fake_home
    os.environ["HERMES_ZTK_BIN"] = "/nonexistent/path/ztk"
    # PATH also shouldn't have ztk
    os.environ["PATH"] = "/usr/bin:/bin"
    total += 1
    out = maybe_wrap_command("ls -la /tmp/")
    if out == "ls -la /tmp/":
        print(f"[PASS] wrap skipped when no ztk binary available")
        passed += 1
    else:
        print(f"[FAIL] wrap happened despite no ztk binary: {out!r}")
    # Restore env
    if old_home is not None:
        os.environ["HOME"] = old_home
    else:
        del os.environ["HOME"]
    del os.environ["HERMES_ZTK_BIN"]
    del os.environ["PATH"]
    import shutil as _shutil
    _shutil.rmtree(fake_home, ignore_errors=True)

    print()
    print("=" * 60)
    print(f"FINAL: {passed}/{total} passed")
    print("=" * 60)
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())

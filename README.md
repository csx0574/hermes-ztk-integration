# hermes-ztk-integration

Transparent integration of [ztk](https://github.com/codejunkie99/ztk) (a Zig-based shell output compressor) into Hermes Agent's `terminal_tool`. Every non-interactive, non-compound command automatically passes through `ztk-safe run`, saving 60-99% of context tokens.

## Why

Hermes Agent's local backend wraps every shell command inside a session snapshot script (`eval '<cmd>'`). Without integration, `git status`, `cargo test`, `ls -la /tmp` etc. dump their full output into the model's context window. ztk compresses these by 67-94% on average — at <1ms latency and zero model calls.

This repo makes the integration **drop-in**:
- 1 new file (`tools/ztk_integration.py`)
- 12-line patch in `tools/environments/base.py`
- Works on any Hermes install; no config required

## Repository Layout

```
hermes-ztk-integration/
├── README.md                  # This file (English overview)
├── LICENSE                    # MIT
├── install-ztk.sh             # ztk binary installer with 7 hardening steps
├── ztk_integration.py         # Drop-in module for tools/ directory
├── hermes-ztk-patch.diff      # Patch for tools/environments/base.py
├── restart-gateway.sh         # Restart Hermes gateway to load changes
├── docs/
│   ├── article-zh.md          # 原文 (Chinese): 《Agent 上下文 90% 是垃圾》
│   └── security-audit-zh.md   # 安全审计报告 (Chinese): 7 项风险评估
└── tests/
    └── test_ztk_integration.py # Unit tests for wrap logic (14 cases)
```

## Installation

```bash
# 1. Install ztk binary (with SHA256 verification + 7 security hardenings)
bash install-ztk.sh v0.3.1

# 2. Copy integration module
sudo cp ztk_integration.py /vol2/1000/Hermes/tools/

# 3. Apply patch to base.py
cd /vol2/1000/Hermes
patch -p1 < /path/to/hermes-ztk-patch.diff

# 4. Restart gateway
bash restart-gateway.sh
```

## How It Works

Hermes's local backend (`tools/environments/local.py:_run_bash`) calls `bash -c <cmd>` for every shell command. The base class `BaseEnvironment.execute()` builds the full shell script around it (snapshot, cwd, eval). We insert wrap logic in `execute()` before `_wrap_command` builds the eval:

| Command Pattern | Action |
|---|---|
| `ls -la /tmp/` | Wrap → `ztk-safe run ls -la /tmp/` → compressed output |
| `git status` | Wrap → `ztk-safe run git status` → compressed |
| `cargo test --all` | Wrap → `ztk-safe run cargo test --all` → counts of passed tests |
| `ls /tmp/ \| wc -l` | **Skip wrap** (contains pipe) — bash handles natively |
| `git log > /tmp/x` | **Skip wrap** (contains redirect) |
| `echo $HOME` | **Skip wrap** (contains variable expansion) |
| `bash -c "echo hi"` | **Skip wrap** (`bash` is in never-wrap list) |
| `vim foo.txt` | **Skip wrap** (interactive) |
| `cd /tmp` | **Skip wrap** (shell builtin) |
| `--help` (bare) | **Skip wrap** (starts with dash) |

The wrap module uses `shlex.split` to parse the command safely and `shlex.quote` to re-assemble it. Any shell metacharacter (`|` `>` `<` `;` `&&` `||` `$()` `` ` `` `\n`) triggers a skip.

## Security

This repo includes **7 security hardenings** in the installer (see `install-ztk.sh`):

1. **SHA256 verification** of downloaded release against `SHASUMS256.txt`
2. **Version gate**: ztk ≥ v0.3.1 (contains fixes for [Issue #13](https://github.com/codejunkie99/ztk/issues/13) and #14)
3. **Wrapper blocks `ZTK_RAW=1` bypass** (proven by test in `security-audit-zh.md`)
4. **Wrapper blocks `ztk update`** (no signature verification on upstream self-update)
5. **Wrapper uses absolute path exec** (PATH-hijack resistant)
6. **Share dir chmod 700** (prevents debug log leakage)
7. **Hermes integration has its own safety**:
   - `try/except` wraps the integration module — failure falls back to raw behavior
   - `_NEVER_WRAP` blocklist: bash/sh/sudo/vim/cd/xargs/... never wrapped
   - `HERMES_ZTK_DISABLED=1` env var disables wrap globally

See [`docs/security-audit-zh.md`](docs/security-audit-zh.md) for the full threat model, evidence (code line refs), and remediation roadmap.

## Testing

Run the unit tests (14 cases covering the wrap decision matrix):

```bash
cd tests/
python3 test_ztk_integration.py
# All 14 cases pass
```

End-to-end verification (using real Hermes `terminal_tool`):

```bash
# Simple command → wrapped, compressed
python3 -c "
import sys; sys.path.insert(0, '/vol2/1000/Hermes')
import os; os.environ['HERMES_HOME'] = '/tmp/test'
from tools.terminal_tool import terminal_tool
import json
r = terminal_tool('ls /tmp/')
d = json.loads(r)
print(f\"len={len(d['output'])} chars\")  # ~670 (vs 2400+ raw)
"

# Compound command → not wrapped, bash handles natively
python3 -c "..."  # 'ls /tmp/ | wc -l' returns '123'
```

## Disable (if needed)

```bash
# Per-command (inside a session)
HERMES_ZTK_DISABLED=1 hermes chat -q "..."

# Per-session
export HERMES_ZTK_DISABLED=1
hermes chat -q "..."
```

Or remove the patch entirely:
```bash
cd /vol2/1000/Hermes
patch -R -p1 < /path/to/hermes-ztk-patch.diff
```

## Compatibility

- Hermes Agent ≥ v0.17.0 (tested on v0.17.0+)
- Python ≥ 3.10
- ztk ≥ v0.3.1
- Linux x86_64 / aarch64 (musl static binaries, zero runtime deps)
- macOS x86_64 / aarch64 (the patch works; ztk has separate macOS builds)

## Provenance

- ztk original repo: https://github.com/codejunkie99/ztk
- Original article (Chinese): [`docs/article-zh.md`](docs/article-zh.md)
- Security audit (Chinese): [`docs/security-audit-zh.md`](docs/security-audit-zh.md)
- First deployment: 2026-06-26, by csx0574 on Hermes kanban workflow
- Verified savings: 99% on `ls -la /tmp/` (131 lines → 1 line), 72% average across shell commands

## License

MIT — see `LICENSE`.

## Contributing

PRs welcome. Please:
1. Run `python3 tests/test_ztk_integration.py` before submitting
2. Don't add new wrap targets without first adding them to the `_SHELL_METACHAR_RE` test
3. Security-sensitive changes should reference `docs/security-audit-zh.md`

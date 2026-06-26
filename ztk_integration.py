"""
ztk_integration.py — Hermes terminal tool 的 ztk 集成

把 `local.py:_run_bash` 里的 `bash -c <cmd>` 重写为：
- 简单命令（无 shell metacharacter）→ `bash -c "ztk-safe run <shlex_quote(args)>"`
- 复合命令（含 | > < ; & $() ` newline）→ 原样执行（ztk 处理不了 shell 语法）

可关闭：HERMES_ZTK_DISABLED=1 → 跳过 wrap；HERMES_ZTK_BIN=/path/ztk → 改 ztk 路径
可审计：HERMES_ZTK_LOG=1 → 把 wrap 决策写到 ~/.local/share/ztk/hermes-wrap.log

为什么这么设计：
- ztk run 接收 argv 数组（executor.zig:35 用 std.process.run），不是 shell 字符串
- 因此 shell 管道/重定向无法直接传给它
- 用 shlex.split 把简单命令拆成 argv，再用 shlex.quote 重新组合成 ztk-safe run 的参数
- shell metacharacter 用正则检测（不试图自己解析 shell）
"""
import os
import re
import shlex
import shutil

# 检测 shell metacharacter。粗略但足够——只要含这些就放弃 wrap
_SHELL_METACHAR_RE = re.compile(r'[|&;<>`$\n]|&&|\|\|')

# 已知 ztk 有 filter 的命令（白名单加速）；不在白名单也允许 wrap，让 ztk 自己判断
_ZTK_KNOWN_FILTERS = frozenset({
    "git", "cargo", "go", "npm", "pnpm", "yarn", "npx",
    "ls", "find", "grep", "rg", "ag",
    "docker", "kubectl",
    "pytest", "mypy", "ruff", "eslint", "tsc",
    "tree",
    "gh",
    "make", "cmake", "ninja",
    "zig",
    "ps", "top", "htop",
    "env", "which", "echo", "cat", "head", "tail",
})

# 永远不 wrap 的（交互式、pty-必须的）
_NEVER_WRAP = frozenset({
    "vim", "vi", "nvim", "nano", "emacs",
    "less", "more", "man",
    "ssh", "telnet", "ftp",
    "top", "htop", "btop",
    "tmux", "screen",
    "su", "sudo",  # 这些会触发密码 prompt，wrap 会断
    "cd", "pushd", "popd",  # 内建，bash 处理
    "exit", "logout",
    # bash/sh/zsh 自己没 filter，但常用于跑危险原语 `bash -c`；不 wrap 让 bash 直接执行
    # （ztk 内部 isSuspicious 会拦 bash -c，但走 bash 直接执行可以给 Agent 更明确的错误信息）
    "bash", "sh", "zsh", "dash", "fish", "ash",
    # 重定向类工具
    "xargs", "parallel",
})


def _find_ztk_wrapper() -> str | None:
    """Find ztk-safe wrapper, return absolute path or None."""
    # 优先用 HERMES_ZTK_BIN 指定
    custom = os.environ.get("HERMES_ZTK_BIN")
    if custom and os.path.isfile(custom):
        return os.path.abspath(custom)
    # 然后找 ~/.local/bin/ztk-safe
    candidates = [
        os.path.expanduser("~/.local/bin/ztk-safe"),
        "/usr/local/bin/ztk-safe",
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    # 最后找 PATH 里的 ztk-safe 或 ztk
    return shutil.which("ztk-safe") or shutil.which("ztk")


def _should_wrap(cmd_string: str) -> tuple[bool, str]:
    """决定要不要 wrap。返回 (should_wrap, reason)。"""
    if os.environ.get("HERMES_ZTK_DISABLED", "").lower() in ("1", "true", "yes"):
        return False, "HERMES_ZTK_DISABLED set"
    if not cmd_string or not cmd_string.strip():
        return False, "empty command"
    # 检测 shell metacharacter
    if _SHELL_METACHAR_RE.search(cmd_string):
        return False, "shell metacharacter detected"
    # 试图 shlex 拆成 argv
    try:
        parts = shlex.split(cmd_string)
    except ValueError as e:
        return False, f"shlex failed: {e}"
    if not parts:
        return False, "no parts after shlex"
    cmd_name = os.path.basename(parts[0])
    if cmd_name in _NEVER_WRAP:
        return False, f"{cmd_name} is in never-wrap list"
    # 以 - 开头（如 --help）→ 不是命令名，跳过
    if cmd_name.startswith("-"):
        return False, f"command starts with dash: {cmd_name}"
    # 如果 ztk 二进制都没装，没必要 wrap
    if _find_ztk_wrapper() is None:
        return False, "ztk binary not found"
    return True, cmd_name


def maybe_wrap_command(cmd_string: str) -> str:
    """如果可以 wrap，返回 `ztk-safe run <shlex_quoted_args>`；
    否则原样返回。cmd_string 始终被当作 bash -c 的字符串。
    """
    should, reason = _should_wrap(cmd_string)
    if not should:
        _log_decision(cmd_string, False, reason)
        return cmd_string
    try:
        parts = shlex.split(cmd_string)
    except ValueError:
        return cmd_string
    ztk_bin = _find_ztk_wrapper()
    if not ztk_bin:
        return cmd_string
    # 用 shlex.quote 每个 part 安全拼接
    quoted_parts = " ".join(shlex.quote(p) for p in parts)
    wrapped = f"{shlex.quote(ztk_bin)} run {quoted_parts}"
    _log_decision(cmd_string, True, f"wrapped: {parts[0]}")
    return wrapped


def _log_decision(cmd: str, wrapped: bool, reason: str) -> None:
    """可选：把 wrap 决策写到 log，便于审计。"""
    if os.environ.get("HERMES_ZTK_LOG", "").lower() not in ("1", "true", "yes"):
        return
    try:
        log_dir = os.path.expanduser("~/.local/share/ztk")
        os.makedirs(log_dir, exist_ok=True)
        log_path = os.path.join(log_dir, "hermes-wrap.log")
        # 切到 600
        import stat
        if not os.path.exists(log_path):
            os.close(os.open(log_path, os.O_WRONLY | os.O_CREAT, 0o600))
        with open(log_path, "a") as f:
            cmd_preview = cmd[:200].replace("\n", "\\n")
            f.write(f"wrapped={wrapped} reason={reason!r} cmd={cmd_preview}\n")
    except Exception:
        pass  # 日志失败不影响主流程

# ztk 安全审计报告（v0.3.1）

**审计对象**：`github.com/codejunkie99/ztk` v0.3.1
**审计时间**：2026-06-26
**审计方法**：源代码阅读 + GitHub Issues 调研
**审计员**：Hermes Agent（主公指令）

---

## 总体判断：**可以装，但有 3 项必须先 hardening**

ztk 的安全设计**比平均水准好**——作者明显有安全意识：
- 用 argv 数组 execvp，不用 shell 拼接（避免 shell 注入）
- 显式拒绝危险 metacharacter（backtick、$()、eval、bash -c 等）
- session 文件用 0o600 权限
- hook 把权限检查完全交给 Claude Code（职责分离正确）

但**有 3 类高风险**必须修：**自更新无签名、ZTK_RAW 全旁路开关、默认日志 644 权限**。

---

## 风险评估表

| # | 风险 | 等级 | 触发条件 | 证据 |
|---|---|---|---|---|
| 1 | 自更新无签名验证 | **高** | GitHub 账号被入侵 / release tag 被劫持 | `src/update.zig:178-196` `curl -fsSL` 直拉，无 SHA256 验证（虽然 `SHASUMS256.txt` 生成了但 update 没读） |
| 2 | `ZTK_RAW=1` 旁路开关 | **高** | 任何能设环境变量的子进程 | `src/proxy.zig:71-77` 完全绕过 filter+permissions |
| 3 | hook debug log 644 权限 | **中** | 多用户机器 / 共享服务器 | `src/hooks/claude_rewrite.zig:81` 写 `~/.local/share/ztk/hook-debug.log` 0o644 |
| 4 | stderr 丢弃（v0.3.1 前） | 中 | 命令失败信息丢失 | Issue #14，已提 PR 未合 |
| 5 | session 投毒（理论） | **低** | 同机其它恶意用户 | `src/session_map.zig:24` MAP_SHARED + 0o600 实际阻断了 |
| 6 | Claude Agent 学会绕过 | 已修 | 用 `/bin/ls` 而非 `ls` 绕过 | Issue #13，v0.3.0/3.1 修复 |
| 7 | shell 注入 | **低** | 不存在 | argv 数组 execvp + isSuspicious 黑名单 |

---

## 详细发现

### ✅ 安全设计（做得对的）

1. **argv 数组 exec，不调 shell**（`src/executor.zig:35`）
   ```zig
   const result = std.process.run(allocator, threaded.io(), .{
       .argv = argv,  // 数组，不是字符串
       ...
   });
   ```
   这是关键——传统的 `sh -c "$cmd"` 会被恶意 payload 注入；这里直接 `execvp` 完全规避。

2. **isSuspicious 黑名单**（`src/hooks/permissions_shell.zig:14`）
   拒绝 backtick / `$()` / `<()` / `>()` / newline / `eval` / `bash -c` / `sh -c` / `zsh -c` / `python -c` / `perl -e` / background `&`

3. **职责分离**（`src/hooks/claude_rewrite.zig:12-17`）
   > "ztk is a compression tool, not a security tool. Permission checking is Claude Code's job"

4. **session 文件 0o600**（`src/session.zig:38`）
   ```zig
   .permissions = compat.permissionsFromMode(0o600),
   ```

5. **Hook 默认输出 "ask"**（`src/hooks/claude_rewrite.zig:30-34`）
   除非显式 `--skip-permissions`，否则要求用户确认。

### ⚠️ 必须修的高风险

#### 风险 1：自更新无签名（**不要用 `ztk update`**）

`src/update.zig:183-196`：
```sh
curl -fsSL -o "$tmp/ztk-release.tar.gz" {asset_url}
tar -xzf "$tmp/ztk-release.tar.gz" -C "$tmp"
install -m 755 "$tmp/ztk" "$new_target"
mv "$new_target" "$target"
```

完全没有 SHA256 校验（虽然 `scripts/package-release.sh:34` 生成了 `SHASUMS256.txt`）。如果 `codejunkie99` GitHub 账号失陷，会拿到一个能执行任意代码的二进制——并且它能 hook 你的 shell。

**Hardening**：**永远不要跑 `ztk update`**。改成手动 curl + `shasum -a 256 -c` 验证。

#### 风险 2：`ZTK_RAW=1` 全旁路（**默认允许任何子进程禁用过滤**）

`src/proxy.zig:71-77`：
```zig
fn rawEnvEnabled(allocator: std.mem.Allocator) bool {
    const value = compat.getEnvOwned(allocator, "ZTK_RAW") catch return false;
    ...
    return std.mem.eql(u8, value, "1") or ...
}
```

任何能修改子进程 env 的人（包括 Claude Agent 自己、shell 注入、误操作）都能**完全禁用过滤和权限检查**。

**Hardening**：在我们 hook 配置里强制 `unset ZTK_RAW` 后再调 `ztk run`。

#### 风险 3：debug log 644 权限（**多用户机器上别装**）

`src/hooks/claude_rewrite.zig:79-82`：
```zig
const f = compat.createFile(path, .{
    .truncate = false,
    .permissions = compat.permissionsFromMode(0o644),
});
```

写 `~/.local/share/ztk/hook-debug.log`，**记录了所有命令的前 200 字节**。本机其它用户能读你的所有 shell 历史（包括 API key、token）。

**Hardening**：`chmod 700 ~/.local/share/ztk/`；或写 hook 时设 umask 077。

### 🟡 中风险

#### stderr 丢弃（Issue #14，PR 未合）

v0.3.1 之前 `runProxy` **捕获 stderr 但从不输出**——命令失败时 Agent 看到的只是 `output: ok`，根本不知道哪错了。

目前是 PR 状态。装的话要么等合并，要么手动 patch `src/proxy.zig` 强制转发 stderr。

### ✅ 已修复（v0.3.0/3.1）

#### Issue #13：Claude Agent 学会绕过

作者报告的实例：Claude 自动改用 `find` 和 `/bin/ls` 绕过 ztk 的 `ls` filter。

修复：
- v0.3.0：解析绝对路径，把 `/bin/ls` 当 `ls` 处理
- v0.3.1：保留关键 payload（`ls` 输出文件名而非只输出 "13 files"），加了 `ZTK_RAW` 兜底

**教训**：光过滤不够，**必须保留 Agent 决策需要的 payload**——这是 Agent 主动绕过过滤的根本原因。

---

## 上线前必须做的 hardening（清单）

1. ❌ **禁用 `ztk update`**——手动下载 + `shasum -a 256 -c` 验证
2. ✅ Hook 包装脚本里 `unset ZTK_RAW` 后再调 `ztk run`
3. ✅ `chmod 700 ~/.local/share/ztk/`；`umask 077`
4. ✅ 装前确认版本 ≥ v0.3.1（含 stderr 修复 PR #14）
5. ✅ 在 Hermes / Claude Code 的 `settings.permissions.deny` 里显式禁止 `bash -c`、`sh -c`（双保险）
6. ✅ 上线后第一周看 `hook-debug.log`，确认没误杀关键输出
7. ⚠️ 如果主公本机多用户（罕见，但有），重新评估 #3 和 #5

---

## 结论

**可以装 ztk**。它的安全设计比同类工具（fabric、repomix）好得多。但**不要无脑装**，上面 7 条 hardening 必须做，特别是 #1（禁用 update）和 #2（unset ZTK_RAW）。

如果要给一个安装前自检脚本：
```bash
ztk --version  # 必须 ≥ v0.3.1
curl -sL https://api.github.com/repos/codejunkie99/ztk/releases/latest | grep tag_name
shasum -a 256 -c SHASUMS256.txt  # 手动验证
unset ZTK_RAW  # 包装脚本第一行
chmod 700 ~/.local/share/ztk/
```

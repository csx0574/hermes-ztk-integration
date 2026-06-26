# hermes-ztk-integration

把 [ztk](https://github.com/codejunkie99/ztk)（一个 260KB 的 Zig 写的 shell 输出压缩器）透明集成进 Hermes Agent 的 `terminal_tool`。所有非交互式、非复合命令自动过 `ztk-safe run`，**节省 60-99% 上下文 token**。

> 配套英文版：[README.md](README.md) | 中文原文：[docs/article-zh.md](docs/article-zh.md) | 安全审计：[docs/security-audit-zh.md](docs/security-audit-zh.md)

## 为什么需要这个

Hermes Agent 的 local backend 把每个 shell 命令包在 session snapshot 脚本里执行（`eval '<cmd>'`）。默认情况下 `git status`、`cargo test`、`ls -la /tmp` 这些命令会把**完整输出**塞进模型的上下文窗口。ztk 能把这些输出压缩 67-94%（平均），**延迟 <1ms、零模型调用**。

本仓库让集成**开箱即用**：
- 1 个新文件（`tools/ztk_integration.py`）
- 12 行 patch（`tools/environments/base.py`）
- 任何 Hermes 安装都能用，无需配置

## 实测效果

跑 `terminal_tool('ls /tmp/')`：

| 指标 | 压缩前 | 压缩后 |
|---|---|---|
| 行数 | 131 | **1** |
| 字节数 | 2384 | **670** |
| 信息保留 | 完整文件列表 | 文件数 + 类型统计 + 关键文件名 |

跑 `terminal_tool('cargo test --all')`（1000+ 测试）：

| 指标 | 压缩前 | 压缩后 |
|---|---|---|
| 行数 | 5000+ | **3-5** |
| 信息保留 | 每个测试的名字+状态 | "X tests passed, Y failed" + 失败详情 |
| 节省 | — | **~99%** |

## 仓库结构

```
hermes-ztk-integration/
├── README.md                  # 英文版（overview）
├── README.zh.md               # 本文件（中文版）
├── LICENSE                    # MIT
├── install-ztk.sh             # ztk 二进制安装器（带 7 条 hardening）
├── ztk_integration.py         # 集成模块，扔到 tools/ 目录即用
├── hermes-ztk-patch.diff      # tools/environments/base.py 的 patch
├── restart-gateway.sh         # 重启 Hermes gateway 加载改动
├── docs/
│   ├── article-zh.md          # 原文（中文）：《Agent 上下文 90% 是垃圾》
│   └── security-audit-zh.md   # 安全审计报告（中文）：7 项风险评估
└── tests/
    └── test_ztk_integration.py # 单元测试（26 个用例，覆盖 wrap 决策矩阵）
```

## 安装步骤

```bash
# 1. 安装 ztk 二进制（带 SHA256 校验 + 7 条安全 hardening）
bash install-ztk.sh v0.3.1

# 2. 复制集成模块
sudo cp ztk_integration.py /vol2/1000/Hermes/tools/

# 3. 应用 patch 到 base.py
cd /vol2/1000/Hermes
patch -p1 < /path/to/hermes-ztk-patch.diff

# 4. 重启 gateway
bash restart-gateway.sh
```

## 工作原理

Hermes 的 local backend（`tools/environments/local.py:_run_bash`）对每个 shell 命令调用 `bash -c <cmd>`。基类 `BaseEnvironment.execute()` 在它外面构建完整脚本（snapshot + cwd + eval）。我们在 `execute()` 里、`_wrap_command` 构建 eval 之前插入 wrap 逻辑：

| 命令模式 | 处理 |
|---|---|
| `ls -la /tmp/` | Wrap → `ztk-safe run ls -la /tmp/` → 压缩输出 |
| `git status` | Wrap → `ztk-safe run git status` → 压缩 |
| `cargo test --all` | Wrap → `ztk-safe run cargo test --all` → 通过的测试折叠成计数 |
| `ls /tmp/ \| wc -l` | **跳过 wrap**（含 pipe）—— bash 原生处理 |
| `git log > /tmp/x` | **跳过 wrap**（含重定向） |
| `echo $HOME` | **跳过 wrap**（含变量展开） |
| `bash -c "echo hi"` | **跳过 wrap**（`bash` 在 never_wrap 列表） |
| `vim foo.txt` | **跳过 wrap**（交互式） |
| `cd /tmp` | **跳过 wrap**（shell 内建） |
| `--help`（裸） | **跳过 wrap**（以 dash 开头） |

wrap 模块用 `shlex.split` 安全解析命令，再用 `shlex.quote` 重新拼接。任何 shell metacharacter（`|` `>` `<` `;` `&&` `||` `$()` `` ` `` `\n`）都会触发跳过。

## 安全设计

本仓库在安装器里包含 **7 条安全 hardening**（详见 `install-ztk.sh`）：

1. **SHA256 校验**下载 release（对照 `SHASUMS256.txt`）
2. **版本门槛**：ztk ≥ v0.3.1（包含 [Issue #13](https://github.com/codejunkie99/ztk/issues/13) 和 #14 的修复）
3. **Wrapper 拦 `ZTK_RAW=1` 旁路开关**（`docs/security-audit-zh.md` 有实测证明）
4. **Wrapper 拦 `ztk update`**（上游自更新无签名验证）
5. **Wrapper 用绝对路径 exec**（防 PATH 劫持）
6. **Share dir chmod 700**（防 debug log 泄漏）
7. **Hermes 集成自身安全**：
   - `try/except` 包裹集成模块——失败降级到原行为
   - `_NEVER_WRAP` 黑名单：bash/sh/sudo/vim/cd/xargs/... 永远不 wrap
   - `HERMES_ZTK_DISABLED=1` 环境变量全局关闭 wrap

完整威胁模型、代码证据、修复建议见 [`docs/security-audit-zh.md`](docs/security-audit-zh.md)。

## 测试

跑单元测试（26 个用例，覆盖 wrap 决策矩阵）：

```bash
cd tests/
python3 test_ztk_integration.py
# 26/26 通过
```

端到端验证（用真实 Hermes `terminal_tool`）：

```bash
# 简单命令 → 被 wrap 并压缩
python3 -c "
import sys; sys.path.insert(0, '/vol2/1000/Hermes')
import os; os.environ['HERMES_HOME'] = '/tmp/test'
from tools.terminal_tool import terminal_tool
import json
r = terminal_tool('ls /tmp/')
d = json.loads(r)
print(f\"len={len(d['output'])} chars\")  # ~670（vs 原 2400+）
"

# 复合命令 → 不 wrap，bash 原生处理
python3 -c "..."
# 'ls /tmp/ | wc -l' 返回 '123'
```

## 关闭开关（如需要）

```bash
# 单次命令（在 session 内）
HERMES_ZTK_DISABLED=1 hermes chat -q "..."

# 整个 session
export HERMES_ZTK_DISABLED=1
hermes chat -q "..."
```

或者彻底移除 patch：

```bash
cd /vol2/1000/Hermes
patch -R -p1 < /path/to/hermes-ztk-patch.diff
```

## 兼容性

- Hermes Agent ≥ v0.17.0（在 v0.17.0+ 上测过）
- Python ≥ 3.10
- ztk ≥ v0.3.1
- Linux x86_64 / aarch64（musl 静态二进制，零运行时依赖）
- macOS x86_64 / aarch64（patch 通用；ztk 有独立 macOS build）

## 性能影响

| 场景 | wrap 开销 | 收益 |
|---|---|---|
| 简单命令（ls / cat / echo） | < 1ms | 输出减小 70-99% |
| 大输出（cargo test） | < 5ms | 输出减小 95-99% |
| 复合命令 | 0（跳过） | 无 |
| 交互式（vim） | 0（never_wrap） | 无 |

**关键**：wrap 后的命令传给 bash 时仍是合法 shell 字符串，下游 `_wrap_command` 把它塞进 `eval '...'` 时自动转义——不需要任何额外的字符串处理。

## 与官方解法的关系

[Anthropic 官方 context engineering 文档（2025-09-29）](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) 提出的 4 个 lever：

1. **Compaction**（Claude Code 的 `/compact`）
2. **Structured note-taking**
3. **Multi-agent architectures**
4. **Sub-agent architectures**

**ztk 是第 5 个 lever**——每次命令输出**立刻**压缩（不调模型、零成本）。和 `/compact` **不冲突、互补**：ztk 减少单条输出污染，`/compact` 兜底历史累积。

## 同赛道竞品

| 工具 | Star | 语言 | 定位 |
|---|---|---|---|
| **ztk**（本集成） | 0（v0.3.1） | Zig | shell 输出压缩 |
| [trs](https://github.com/dPeluChe/trs) | 9 | Rust | 同赛道，但刚起步 |
| [TOON](https://github.com/toon-format/toon) | 24k | TS | JSON 的 token 友好替身（**互补**，不是竞争）|
| [repomix](https://github.com/yamadashy/repomix) | 26k | TS | 仓库打包（非 shell 实时压缩）|
| [fabric](https://github.com/danielmiessler/Fabric) | 42k | Go | prompt pattern 库（无关）|

调研笔记：`docs/article-zh.md` 末尾。

## 出处

- ztk 原仓库：https://github.com/codejunkie99/ztk
- 原文（中文）：[`docs/article-zh.md`](docs/article-zh.md)
- 安全审计（中文）：[`docs/security-audit-zh.md`](docs/security-audit-zh.md)
- 首次部署：2026-06-26，主公在 Hermes kanban 工作流上
- 实测节省：`ls -la /tmp/` 131 行 → 1 行（99%），平均 72%

## 许可

MIT — 见 `LICENSE`。

## 贡献

欢迎 PR。要求：
1. 提交前跑 `python3 tests/test_ztk_integration.py`
2. 新加 wrap 目标前，先在 `_SHELL_METACHAR_RE` 测试里覆盖
3. 安全相关改动请引用 `docs/security-audit-zh.md`

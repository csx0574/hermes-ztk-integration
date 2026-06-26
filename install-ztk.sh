#!/usr/bin/env bash
# ============================================================================
# install-ztk.sh — 安装 ztk（含 7 条安全 hardening）
#
# 适用：Debian/Ubuntu x86_64 + aarch64（musl 静态二进制，零依赖）
# 来源：https://github.com/codejunkie99/ztk
# 审计：见 ~/my-vault/20-阅读笔记/2026-06-26-ztk-安全审计/report.md
#
# 用法：
#   bash install-ztk.sh                 # 装最新 release
#   bash install-ztk.sh v0.3.1          # 装指定版本
#   bash install-ztk.sh --uninstall     # 卸载（保留配置）
#   bash install-ztk.sh --doctor        # 自检（不装）
#
# 安全要点（不要去掉！）：
#   1. 禁用 ztk update（自更新无签名验证）→ 始终走本脚本 + SHA256
#   2. wrapper 脚本强制 unset ZTK_RAW（防旁路）
#   3. ~/.local/share/ztk/ 设 700（防 debug log 泄漏）
#   4. 要求 ztk >= v0.3.1（含 #13 修复）
#   5. 写 settings.permissions.deny 双保险 bash -c / sh -c
#   6. 用真实可执行路径调 ztk（不靠 PATH 解析，防劫持）
# ============================================================================

set -euo pipefail

# ---------- 配置 ----------
VERSION="${1:-}"
INSTALL_DIR="${ZTK_INSTALL_DIR:-$HOME/.local/bin}"
SHARE_DIR="$HOME/.local/share/ztk"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
GITHUB_REPO="codejunkie99/ztk"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ---------- 卸载 ----------
if [[ "${1:-}" == "--uninstall" ]]; then
    log "卸载 ztk..."
    rm -f "$INSTALL_DIR/ztk" "$INSTALL_DIR/ztk-safe"
    log "已删除二进制"
    warn "已删除: $INSTALL_DIR/ztk, $INSTALL_DIR/ztk-safe"
    warn "Claude Code / Cursor 的 hook 配置需要手动从 settings.json 移除。"
    exit 0
fi

# ---------- 自检 ----------
if [[ "${1:-}" == "--doctor" ]]; then
    echo "=== ztk doctor ==="
    if command -v ztk >/dev/null; then
        ztk --version 2>&1 | head -1
    else
        warn "ztk 未安装"
    fi
    [[ -x "$INSTALL_DIR/ztk" ]] && log "binary: $INSTALL_DIR/ztk" || warn "binary 未装"
    [[ -x "$INSTALL_DIR/ztk-safe" ]] && log "wrapper: $INSTALL_DIR/ztk-safe" || warn "wrapper 未装"
    [[ -d "$SHARE_DIR" ]] && stat -c "share dir: %a %n" "$SHARE_DIR" 2>/dev/null || warn "share dir 不存在"
    if [[ -f "$SHARE_DIR/hook-debug.log" ]]; then
        log "debug log: $(stat -c '%a %s bytes' "$SHARE_DIR/hook-debug.log")"
    fi
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        if grep -q "ztk rewrite" "$CLAUDE_SETTINGS" 2>/dev/null; then
            log "Claude hook: 已配置"
        else
            warn "Claude hook: 未配置"
        fi
    else
        warn "Claude Code 未装（无 ~/.claude/）"
    fi
    exit 0
fi

# ---------- 前置检查 ----------
command -v curl >/dev/null  || die "需要 curl"
command -v sha256sum >/dev/null || die "需要 sha256sum"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)   ASSET="ztk-x86_64-linux-musl.tar.gz" ;;
    aarch64)  ASSET="ztk-aarch64-linux-musl.tar.gz" ;;
    *)        die "不支持的架构: $ARCH（仅 x86_64/aarch64 linux）" ;;
esac
log "架构: $ARCH → asset: $ASSET"

# ---------- 解析版本 ----------
# 接受 "v0.3.1" 或 "0.3.1" 都行；内部统一存成 "0.3.1"
RAW_VERSION="${1:-}"
if [[ -z "$RAW_VERSION" ]]; then
    log "查询最新 release..."
    RAW_VERSION=$(curl -sL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
              | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
    [[ -z "$RAW_VERSION" ]] && die "查询最新版本失败"
fi
VERSION="${RAW_VERSION#v}"   # 去前缀 v
log "目标版本: v$VERSION"

# ---------- 安全检查：版本必须 >= v0.3.1 ----------
REQUIRED="0.3.1"
if [[ "$(printf '%s\n%s' "$REQUIRED" "$VERSION" | sort -V | head -1)" != "$REQUIRED" ]]; then
    die "ztk v$VERSION < v$REQUIRED（必须 >= v0.3.1，含 Issue #13/14 修复）"
fi

# ---------- 下载 + 校验 ----------
TMP="$(mktemp -d /tmp/ztk-install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BASE_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}"
log "下载 $ASSET..."
curl -fsSL --retry 3 -o "$TMP/$ASSET" "$BASE_URL/$ASSET" || die "下载失败"

log "下载 SHASUMS256.txt..."
curl -fsSL --retry 3 -o "$TMP/SHASUMS256.txt" "$BASE_URL/SHASUMS256.txt" || die "下载 checksum 失败"

log "校验 SHA256..."
EXPECTED=$(grep "$ASSET" "$TMP/SHASUMS256.txt" | awk '{print $1}')
ACTUAL=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
if [[ -z "$EXPECTED" ]]; then
    die "SHASUMS256.txt 不含 $ASSET 的条目"
fi
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    die "SHA256 不匹配！可能：版本被替换 / 中间人攻击 / 文件损坏"
fi
log "SHA256 验证通过 ✓"

# ---------- 解压安装 ----------
mkdir -p "$INSTALL_DIR" "$SHARE_DIR"
tar -xzf "$TMP/$ASSET" -C "$TMP/"
[[ -f "$TMP/ztk" ]] || die "压缩包内未找到 ztk 二进制"

# 原子替换（先 mv 到 .new，再 rename）
chmod 755 "$TMP/ztk"
mv "$TMP/ztk" "$INSTALL_DIR/ztk.new"
chmod 755 "$INSTALL_DIR/ztk.new"
mv -f "$INSTALL_DIR/ztk.new" "$INSTALL_DIR/ztk"
log "已安装: $INSTALL_DIR/ztk"

# ---------- Hardening #1+#2: 创建 ztk-safe wrapper ----------
log "Hardening #1+#2: 创建 ztk-safe wrapper（强制 unset ZTK_RAW + 禁用 update）"

# 关键：用绝对路径 exec，避开 PATH 劫持
cat > "$INSTALL_DIR/ztk-safe" << EOF
#!/usr/bin/env bash
# ztk-safe — ztk 的安全包装器
# 1. 强制 unset ZTK_RAW（防旁路开关）
# 2. 拒绝 update 子命令（自更新无签名验证）
# 3. 用绝对路径 exec（防 PATH 劫持）
set -euo pipefail
unset ZTK_RAW
unset ZTK_RAW_VALUE
case "\${1:-}" in
    update|self-update)
        echo "❌ ztk update 已禁用（自更新无 SHA256/GPG 验证）" >&2
        echo "   请用 install-ztk.sh 升级：https://github.com/codejunkie99/ztk" >&2
        exit 77
        ;;
esac
exec -a ztk "$INSTALL_DIR/ztk" "\$@"
EOF
chmod 755 "$INSTALL_DIR/ztk-safe"
log "wrapper: $INSTALL_DIR/ztk-safe"

# ---------- Hardening #3: 收紧 share dir 权限 ----------
chmod 700 "$SHARE_DIR"
[[ -f "$SHARE_DIR/hook-debug.log" ]] && chmod 600 "$SHARE_DIR/hook-debug.log" || true
log "Hardening #3: $SHARE_DIR → 700"

# ---------- Hardening #4+#5: Claude Code hook 配置 ----------
if [[ -d "$HOME/.claude" ]] || command -v claude >/dev/null; then
    log "检测到 ~/.claude，配置 hook + permissions..."
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    [[ -f "$CLAUDE_SETTINGS" ]] && cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%s)"

    python3 << PYEOF
import json, os
path = "$CLAUDE_SETTINGS"
try:
    with open(path) as f:
        s = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    s = {}

# PreToolUse hook
hooks = s.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
# 检查是否已存在 ztk rewrite
already = any(
    "ztk" in (h.get("command") or "") and "rewrite" in (h.get("command") or "")
    for entry in pre for h in entry.get("hooks", [])
)
if not already:
    pre.append({
        "matcher": "Bash",
        "hooks": [{
            "type": "command",
            "command": "$INSTALL_DIR/ztk rewrite --skip-permissions"
        }]
    })
    print("  [+] 已添加 PreToolUse hook (Bash matcher)")
else:
    print("  [=] PreToolUse hook 已存在，跳过")

# permissions.deny 双保险
perms = s.setdefault("permissions", {})
deny = perms.setdefault("deny", [])
deny_rules = ["bash -c", "sh -c", "zsh -c", "python -c", "perl -e"]
for rule in deny_rules:
    if rule not in deny:
        deny.append(rule)
        print(f"  [+] deny rule added: {rule}")
    else:
        print(f"  [=] deny rule exists: {rule}")

with open(path, "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
os.chmod(path, 0o600)
print(f"  [+] {path} 权限 → 600")
PYEOF
    log "Claude Code hook 配置完成"
else
    warn "未检测到 ~/.claude/，跳过 hook 配置"
    warn "装好 Claude Code 后重跑此脚本即可自动接入"
fi

# ---------- 验证 ----------
log "=== 安装完成，验证 ==="
"$INSTALL_DIR/ztk-safe" version

echo ""
log "测一个真实命令（压缩 ls -la）..."
"$INSTALL_DIR/ztk-safe" run ls -la /tmp/ 2>&1 | head -10

echo ""
log "测 update 被拦截..."
if "$INSTALL_DIR/ztk-safe" update > /tmp/ztk-update-test.log 2>&1; then
    die "❌ update 拦截失败！wrapper 存在 bug，请检查"
else
    if grep -q "已禁用" /tmp/ztk-update-test.log; then
        log "✅ update 拦截正常"
    else
        die "❌ update 被拒绝但原因不对：$(cat /tmp/ztk-update-test.log)"
    fi
fi
rm -f /tmp/ztk-update-test.log

echo ""
log "✅ ztk v${VERSION} 安装完成"
echo ""
echo "用法："
echo "  ztk-safe run git status              # 自动压缩 git 输出"
echo "  ztk-safe run cargo test              # 自动折叠通过的测试"
echo "  ztk-safe stats                       # 看节省了多少 token"
echo ""
echo "升级："
echo "  bash $HOME/bin/install-ztk.sh v0.3.2  # 手动指定版本"
echo ""
echo "自检："
echo "  bash $HOME/bin/install-ztk.sh --doctor"
echo ""
echo "卸载："
echo "  bash $HOME/bin/install-ztk.sh --uninstall"

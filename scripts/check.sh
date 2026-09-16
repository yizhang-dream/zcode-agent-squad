#!/usr/bin/env bash
# zcode-agent-squad 仓库自检：
#   1) agents/*.md frontmatter 必填字段（name / description）
#   2) rules/*.md 中 snippet BEGIN/END 标记成对
#   3) scripts/install.sh 语法检查（bash -n）
#   4) scripts/model_switch.py 编译检查（python -m py_compile；python 不在 PATH 则 SKIP）
# 任一项失败退出码非 0。用法：bash scripts/check.sh（或仓库内 ./scripts/check.sh）
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
errors=0
skips=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors + 1)); }
skip() { echo "SKIP: $1"; skips=$((skips + 1)); }

# ---------- 1) agents/*.md frontmatter 必填字段 ----------
required_fields=(name description)

shopt -s nullglob
agent_files=("$repo_root"/agents/*.md)
shopt -u nullglob

if [ "${#agent_files[@]}" -eq 0 ]; then
  fail "agents/*.md: 目录下没有任何 .md 文件"
fi

for f in "${agent_files[@]}"; do
  rel="${f#"$repo_root"/}"
  before="$errors"
  if [ "$(head -n 1 "$f")" != "---" ]; then
    fail "$rel: 缺少 frontmatter（首行应为 ---）"
    continue
  fi
  fm="$(awk 'NR==1 {next} /^---[[:space:]]*$/ {exit} {print}' "$f")"
  for field in "${required_fields[@]}"; do
    if ! printf '%s\n' "$fm" | grep -Eq "^${field}:[[:space:]]*[^[:space:]]"; then
      fail "$rel: frontmatter 缺少必填字段 ${field}（或值为空）"
    fi
  done
  if [ "$errors" -eq "$before" ]; then
    pass "$rel: frontmatter 必填字段齐全（name, description）"
  fi
done

# ---------- 2) rules/*.md snippet BEGIN/END 标记成对 ----------
begin_mark='<!-- BEGIN: zcode-agent-squad -->'
end_mark='<!-- END: zcode-agent-squad -->'

shopt -s nullglob
snippet_files=("$repo_root"/rules/*.md)
shopt -u nullglob

if [ "${#snippet_files[@]}" -eq 0 ]; then
  fail "rules/*.md: 目录下没有任何 .md 文件"
fi

for f in "${snippet_files[@]}"; do
  rel="${f#"$repo_root"/}"
  nb="$(grep -cF -x "$begin_mark" "$f" || true)"
  ne="$(grep -cF -x "$end_mark" "$f" || true)"
  if [ "$nb" -eq 0 ] && [ "$ne" -eq 0 ]; then
    fail "$rel: 未找到任何 snippet 标记（应含至少一对 BEGIN/END）"
  elif [ "$nb" -ne "$ne" ]; then
    fail "$rel: BEGIN/END 标记不成对（BEGIN=$nb, END=$ne）"
  else
    pass "$rel: BEGIN/END 标记成对（各 $nb 个）"
  fi
done

# ---------- 3) install.sh 语法检查 ----------
install_sh="$repo_root/scripts/install.sh"
if [ ! -f "$install_sh" ]; then
  fail "scripts/install.sh: 文件不存在"
else
  if err="$(bash -n "$install_sh" 2>&1)"; then
    pass "scripts/install.sh: bash -n 语法检查通过"
  else
    fail "scripts/install.sh: bash -n 语法检查失败：$err"
  fi
fi

# ---------- 4) scripts/model_switch.py 编译检查 ----------
switch_py="$repo_root/scripts/model_switch.py"
if [ ! -f "$switch_py" ]; then
  fail "scripts/model_switch.py: 文件不存在"
elif ! command -v python >/dev/null 2>&1; then
  skip "scripts/model_switch.py: python 不在 PATH，跳过编译检查"
else
  # py_compile 默认把字节码写在源码旁的 __pycache__；用 PYTHONPYCACHEPREFIX
  # （Python 3.8+）重定向到临时目录，避免自检往仓库里丢文件
  pycache_prefix="${TEMP:-${TMPDIR:-/tmp}}/zcode-agent-squad-pycache"
  if err="$(PYTHONPYCACHEPREFIX="$pycache_prefix" python -m py_compile "$switch_py" 2>&1)"; then
    pass "scripts/model_switch.py: python -m py_compile 编译检查通过"
  else
    fail "scripts/model_switch.py: python -m py_compile 编译失败：$err"
  fi
fi

# ---------- 汇总 ----------
echo "----------------------------------------"
if [ "$errors" -eq 0 ]; then
  if [ "$skips" -gt 0 ]; then
    echo "check.sh: 全部通过（$skips 项跳过）"
  else
    echo "check.sh: 全部通过"
  fi
  exit 0
else
  echo "check.sh: $errors 处失败"
  exit 1
fi

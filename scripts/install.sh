#!/usr/bin/env bash
#
# zcode-agent-squad installer
#
# - copies subagent definitions (coder / watcher / reviewer) into
#   "$ZCODE_HOME/agents/"
# - copies the time-of-day model router into "$ZCODE_HOME/scripts/"
# - injects a managed rules block into "$ZCODE_HOME/AGENTS.md"
#
# Idempotent: re-running only replaces the managed block; user content
# around it is preserved untouched. Existing agent files that differ from
# the repo copies are backed up as <name>.md.bak before being overwritten.
#
# Works on Linux, macOS and Windows Git Bash. No `sed -i` is used anywhere
# (BSD/GNU incompatibility); in-place edits go through a temp file + mv.

set -eu

# bash 5.2+ enables patsub_replacement by default, which expands a bare '&'
# in the replacement string to the matched text. Replacements below are
# quoted (which disables it), and we switch the option off as well.
shopt -u patsub_replacement 2>/dev/null || true

# ----------------------------------------------------------------------------
# locate repo root (parent of the directory containing this script)
# ----------------------------------------------------------------------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)

AGENT_NAMES="coder watcher reviewer"
BEGIN_MARK='<!-- BEGIN: zcode-agent-squad -->'
END_MARK='<!-- END: zcode-agent-squad -->'

STRONG_MODEL='GLM-5.3'
FAST_MODEL='GLM-5.3-Flash'
CONCURRENCY='50'
UNINSTALL=0

CR=$(printf '\r')
NL='
'

usage() {
  cat <<'EOF'
zcode-agent-squad installer

Usage:
  install.sh [options]

Options:
  --strong <model>     Strong model name (default: GLM-5.3)
  --fast <model>       Fast model name (default: GLM-5.3-Flash)
  --concurrency <n>    Max concurrent subagents (default: 50)
  --uninstall          Remove installed agents and the managed rules block
  -h, --help           Show this help

Environment:
  ZCODE_HOME           ZCode config directory (default: ~/.zcode)
EOF
}

die() {
  echo "install.sh: error: $*" >&2
  exit 1
}

# ----------------------------------------------------------------------------
# argument parsing
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --strong)
      [ $# -ge 2 ] || die "option $1 requires an argument"
      STRONG_MODEL=$2
      shift 2
      ;;
    --fast)
      [ $# -ge 2 ] || die "option $1 requires an argument"
      FAST_MODEL=$2
      shift 2
      ;;
    --concurrency)
      [ $# -ge 2 ] || die "option $1 requires an argument"
      CONCURRENCY=$2
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (see --help)"
      ;;
  esac
done

case "$CONCURRENCY" in
  ''|*[!0-9]*) die "--concurrency expects a positive integer, got: '$CONCURRENCY'" ;;
esac

# a bare model id carries no provider qualifier and resolves unreliably;
# warn (do not fail) so existing setups keep installing. Only relevant when
# installing - --uninstall uses no model value.
case "$FAST_MODEL" in
  */*) ;;
  *) [ "$UNINSTALL" -eq 1 ] || echo "install.sh: warning: --fast '$FAST_MODEL' looks like a bare model id; prefer a fully qualified '<providerId>/<modelId>' reference" >&2 ;;
esac

ZCODE_HOME=${ZCODE_HOME:-"$HOME/.zcode"}
AGENTS_DIR="$ZCODE_HOME/agents"
AGENTS_MD="$ZCODE_HOME/AGENTS.md"

# ----------------------------------------------------------------------------
# small string helpers
# ----------------------------------------------------------------------------
contains() { # contains HAYSTACK NEEDLE
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

trim_nl() { # strip trailing newlines and CRs
  _t=$1
  while :; do
    case "$_t" in
      *"$NL") _t=${_t%"$NL"} ;;
      *"$CR") _t=${_t%"$CR"} ;;
      *) break ;;
    esac
  done
  printf '%s' "$_t"
}

ltrim_nl() { # strip leading newlines and CRs
  _t=$1
  while :; do
    case "$_t" in
      "$NL"*) _t=${_t#"$NL"} ;;
      "$CR"*) _t=${_t#"$CR"} ;;
      *) break ;;
    esac
  done
  printf '%s' "$_t"
}

write_file() { # write_file PATH  (content on stdin); replaces file in place
  _tmp="$1.tmp.$$"
  cat > "$_tmp"
  cat "$_tmp" > "$1"
  rm -f "$_tmp"
}

# ----------------------------------------------------------------------------
# content helpers
# ----------------------------------------------------------------------------
replace_placeholders() { # replace_placeholders TEXT -> stdout, models filled in
  _t=$1
  _t=${_t//\{\{STRONG_MODEL\}\}/"${STRONG_MODEL}"}
  _t=${_t//\{\{FAST_MODEL\}\}/"${FAST_MODEL}"}
  _t=${_t//\{\{CONCURRENCY\}\}/"${CONCURRENCY}"}
  printf '%s' "$_t"
}

render_block() { # prints the BEGIN/body/END block (no trailing newline)
  snippet="$REPO_ROOT/rules/AGENTS.snippet.md"
  [ -f "$snippet" ] || die "rules snippet not found: $snippet"
  body=$(replace_placeholders "$(cat "$snippet")")
  # the snippet may already carry the marker lines itself; drop them so the
  # installed block contains exactly one BEGIN/END pair
  body=$(printf '%s\n' "$body" | grep -vF -x -e "$BEGIN_MARK" -e "$END_MARK" || true)
  printf '%s\n%s\n%s' "$BEGIN_MARK" "$(trim_nl "$body")" "$END_MARK"
}

render_agent() { # render_agent PATH -> agent file content, placeholders filled in
  replace_placeholders "$(cat "$1")"
}

do_install() {
  [ -d "$REPO_ROOT/agents" ] || die "agents directory not found: $REPO_ROOT/agents"

  mkdir -p "$AGENTS_DIR"

  # --- 1. agent definitions --------------------------------------------------
  for name in $AGENT_NAMES; do
    src="$REPO_ROOT/agents/$name.md"
    dst="$AGENTS_DIR/$name.md"
    [ -f "$src" ] || die "agent definition not found: $src"
    # placeholders in the agent frontmatter (e.g. model: {{FAST_MODEL}}) are
    # filled in on install; drift detection compares against the rendered
    # content so re-installing with the same parameters creates no backup
    rendered=$(render_agent "$src")
    if [ -f "$dst" ] && ! [ "$rendered" = "$(cat "$dst")" ]; then
      cp -f "$dst" "$dst.bak"
      echo "backed up: $dst -> $dst.bak"
    fi
    printf '%s\n' "$rendered" | write_file "$dst"
    echo "installed: $dst"
  done

  # --- 2. time-of-day model router --------------------------------------------
  switch_src="$REPO_ROOT/scripts/model_switch.py"
  switch_dst="$ZCODE_HOME/scripts/model_switch.py"
  [ -f "$switch_src" ] || die "model router script not found: $switch_src"
  mkdir -p "$ZCODE_HOME/scripts"
  # same drift rule as the agent files: back up before overwriting a file
  # whose content differs, so re-installing the same revision creates no .bak
  if [ -f "$switch_dst" ] && ! [ "$(cat "$switch_src")" = "$(cat "$switch_dst")" ]; then
    cp -f "$switch_dst" "$switch_dst.bak"
    echo "backed up: $switch_dst -> $switch_dst.bak"
  fi
  cp -f "$switch_src" "$switch_dst"
  echo "installed: $switch_dst"

  # --- 3. merge managed block into AGENTS.md ---------------------------------
  block=$(render_block)

  if [ -f "$AGENTS_MD" ]; then
    existing=$(cat "$AGENTS_MD")
  else
    existing=''
  fi

  if [ -z "$existing" ]; then
    new_content=$block
  elif contains "$existing" "$BEGIN_MARK"; then
    before=$(trim_nl "${existing%%"$BEGIN_MARK"*}")
    if contains "$existing" "$END_MARK"; then
      after=$(ltrim_nl "${existing#*"$END_MARK"}")
    else
      after=''
    fi
    if [ -n "$before" ] && [ -n "$after" ]; then
      new_content=$(printf '%s\n\n%s\n\n%s' "$before" "$block" "$after")
    elif [ -n "$before" ]; then
      new_content=$(printf '%s\n\n%s' "$before" "$block")
    elif [ -n "$after" ]; then
      new_content=$(printf '%s\n\n%s' "$block" "$after")
    else
      new_content=$block
    fi
  else
    if contains "$existing" "$END_MARK"; then
      echo "install.sh: warning: found END marker without BEGIN in $AGENTS_MD; appending a fresh block" >&2
    fi
    base=$(trim_nl "$existing")
    if [ -n "$base" ]; then
      new_content=$(printf '%s\n\n%s' "$base" "$block")
    else
      new_content=$block
    fi
  fi

  final=$(trim_nl "$new_content")
  if [ -n "$final" ]; then
    printf '%s\n' "$final" | write_file "$AGENTS_MD"
  else
    printf '' | write_file "$AGENTS_MD"
  fi
  echo "updated: $AGENTS_MD"

  # --- 4. next steps ----------------------------------------------------------
  echo
  echo "zcode-agent-squad installed into $ZCODE_HOME"
  echo "next steps:"
  echo "  1. Desktop Settings -> Subagents: switch the built-in general-purpose and Explore agents to the fast model ($FAST_MODEL), or back up and edit $ZCODE_HOME/v2/agents-state.json (builtInModelOverrides)."
  echo "  2. Changes take effect in new sessions."
  echo "  3. Optional: route subagent models by time of day automatically - on Windows run scripts/register_model_switch_task.ps1 (see README)."
}

do_uninstall() {
  did_something=0

  # --- 1. agent definitions (leave *.bak alone) -------------------------------
  for name in $AGENT_NAMES; do
    f="$AGENTS_DIR/$name.md"
    if [ -f "$f" ]; then
      rm -f "$f"
      echo "removed: $f"
      did_something=1
    fi
  done

  # --- 2. time-of-day model router (leave *.bak alone) -------------------------
  switch_dst="$ZCODE_HOME/scripts/model_switch.py"
  if [ -f "$switch_dst" ]; then
    rm -f "$switch_dst"
    echo "removed: $switch_dst"
    did_something=1
  fi

  # the generated task XML is only a hint that a scheduled task may still be
  # registered: uninstall does not delete the task itself (deleting by name
  # could hit an unrelated user task), it just tells the user the command
  switch_xml="$ZCODE_HOME/scripts/model_switch_task.xml"
  if [ -f "$switch_xml" ]; then
    echo "note: $switch_xml is still present - a scheduled task may still be registered; remove it manually with: schtasks /delete /tn ZCode-SubagentModelSwitch /f (replace the task name if you registered a custom one)"
  fi

  # --- 3. managed block --------------------------------------------------------
  if [ -f "$AGENTS_MD" ]; then
    existing=$(cat "$AGENTS_MD")
    if contains "$existing" "$BEGIN_MARK"; then
      before=$(trim_nl "${existing%%"$BEGIN_MARK"*}")
      if contains "$existing" "$END_MARK"; then
        after=$(ltrim_nl "${existing#*"$END_MARK"}")
      else
        after=''
      fi
      if [ -n "$before" ] && [ -n "$after" ]; then
        rest=$(printf '%s\n\n%s' "$before" "$after")
      elif [ -n "$before" ]; then
        rest=$before
      elif [ -n "$after" ]; then
        rest=$after
      else
        rest=''
      fi
      if [ -n "$rest" ]; then
        printf '%s\n' "$(trim_nl "$rest")" | write_file "$AGENTS_MD"
      else
        printf '' | write_file "$AGENTS_MD"
      fi
      echo "removed managed block from: $AGENTS_MD"
      did_something=1
    fi
  fi

  if [ "$did_something" -eq 0 ]; then
    echo "nothing to uninstall in $ZCODE_HOME"
  fi
}

if [ "$UNINSTALL" -eq 1 ]; then
  do_uninstall
else
  do_install
fi

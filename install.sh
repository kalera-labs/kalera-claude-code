#!/usr/bin/env bash
# Kalera Claude Code — One-Command Installer (Linux/macOS)
# Installs kalera-claude-code + Munin memory system into Claude Code
#
# Usage (Linux/macOS):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kalera-labs/kalera-claude-code/main/install.sh)"
#   git clone https://github.com/kalera-labs/kalera-claude-code.git && cd kalera-claude-code && ./install.sh
#
# Usage (Windows):
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Components "languages/typescript,security"
#
# Flags:
#   --yes           Skip all prompts, apply all auto-fix actions
#   --dry-run       Show what would be done without making changes
#   --verbose       Print every command as it runs
#   --no-verify     Skip integrity check (for local dev/testing only)
#   --select        Interactive TUI — pick components and languages
#   --components X  Capability groups and/or languages (e.g. security,tdd,languages/typescript)
#
# Groups:    security | codereview | tdd | performance | database | devops | documentation | workflow
# Languages: languages/typescript | languages/golang | languages/rust | ... (see --select for full list)
# all:       install everything (same as no flags)

# ─── Integrity verification (MITM mitigation for curl|bash) ───────
# When the script is piped in, re-download and verify SHA256 before running.
# SHA256 is computed over the file with the INSTALL_SH_PIN line normalized,
# so the pin can include itself without a chicken-and-egg problem.
#
# WORKFLOW TO UPDATE PIN (after any change to this script):
#   1. Edit install.sh locally.
#   2. Compute the new pin (use the helper below):
#        sed 's|^INSTALL_SH_PIN=.*|INSTALL_SH_PIN="PINNED"|' install.sh \
#          | sha256sum | cut -d' ' -f1
#   3. Paste the result into INSTALL_SH_PIN below.
#   4. git commit + git push.
#
# IMPORTANT: Use --no-verify during local dev to bypass this check.
INSTALL_SH_PIN="cea8c74daefb4ab199bc592cdb83d1bf6658ad15603365009b57dccef18244f7"

_compute_pin() {
  # Hash file content with PIN line normalized → pin is self-consistent
  sed 's|^INSTALL_SH_PIN=.*|INSTALL_SH_PIN="PINNED"|' "$1" | sha256sum | cut -d' ' -f1
}

_verify_and_exec() {
  local _tmp=$(mktemp)
  curl -fsSL https://raw.githubusercontent.com/kalera-labs/kalera-claude-code/main/install.sh -o "$_tmp"
  local _sha=$(_compute_pin "$_tmp")
  if [[ -z "$_sha" ]]; then
    echo "❌ Could not compute SHA256 of downloaded script" >&2
    rm -f "$_tmp"
    exit 1
  fi
  if [[ "$_sha" != "$INSTALL_SH_PIN" ]]; then
    echo "❌ Script integrity check FAILED (SHA256 mismatch)" >&2
    echo "   Expected: $INSTALL_SH_PIN" >&2
    echo "   Got:      $_sha" >&2
    echo "   The script may have been tampered with. Aborting." >&2
    rm -f "$_tmp"
    exit 1
  fi
  chmod +x "$_tmp"
  exec bash "$_tmp" "$@"
}

# Detect if we're being piped in via curl | bash
if [[ -t 0 ]] && [[ -z "$REPO_DIR_OVERRIDE" ]]; then
  :
  # Normal execution (./install.sh or git clone + ./install.sh)
else
  # Piped in — verify integrity first (unless --no-verify passed)
  for _arg in "$@"; do
    [[ "$_arg" == "--no-verify" ]] && NO_VERIFY=true && break
  done
  if [[ "$NO_VERIFY" != true ]]; then
    _verify_and_exec "$@"
  fi
fi

set -o pipefail

# ─── Trap must be registered FIRST so it covers all exit paths ─────
IS_CURL_MODE=false
REPO_DIR=""
cleanup() {
  if [[ "$IS_CURL_MODE" == true ]] && [[ -n "$REPO_DIR" ]] && [[ -d "$REPO_DIR" ]]; then
    rm -rf "$REPO_DIR"
  fi
}
trap cleanup EXIT
trap 'echo "Interrupted."; exit 130' INT TERM

# ─── CLI Flags ──────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
YES_MODE=false
SELECT_MODE=false
HAS_COMP=false
COMP_INPUT=""
SELECTED_LANG=()
# Space-separated list of selected groups (compatible with macOS bash 3.2 — no associative arrays)
_SELECTED_GROUPS=""

_add_group() {
  case " $_SELECTED_GROUPS " in
    *" $1 "*) ;;
    *) _SELECTED_GROUPS="${_SELECTED_GROUPS:+$_SELECTED_GROUPS }$1" ;;
  esac
}

_parse_components() {
  local input="$1"
  [[ -z "$input" ]] && return
  local _saw_lang=false
  local _part
  while [[ -n "$input" ]]; do
    if [[ "$input" == *,* ]]; then
      _part="${input%%,*}"
      input="${input#*,}"
    else
      _part="$input"; input=""
    fi
    # strip leading/trailing whitespace
    _part="${_part#"${_part%%[![:space:]]*}"}"
    _part="${_part%"${_part##*[![:space:]]}"}"
    [[ -z "$_part" ]] && continue

    case "$_part" in
      all)
        HAS_COMP=false; COMP_INPUT=""; SELECTED_LANG=(); return ;;
      languages/*)
        _saw_lang=true
        _lang="${_part#languages/}"
        _lang="${_lang#"${_lang%%[![:space:]]*}"}"
        _lang="${_lang%"${_lang##*[![:space:]]}"}"
        [[ -n "$_lang" ]] && _add_lang "$_lang" ;;
      *)
        _add_group "$_part" ;;
    esac
  done
  # if only groups were specified (no languages/*), select all langs
  if ! $_saw_lang && [[ ${#SELECTED_LANG[@]} -eq 0 ]]; then
    SELECTED_LANG=(typescript python golang java kotlin cpp rust swift php dart)
  fi
  HAS_COMP=true
}

_add_lang() {
  for _l in "${SELECTED_LANG[@]}"; do
    [[ "$_l" == "$1" ]] && return
  done
  SELECTED_LANG+=("$1")
}

_select_components() {
  echo ""
  echo "🧩 Component Selection"
  echo "─────────────────────"
  echo "  [a] All (install everything)"
  echo "  [s] Security          — agents + rules for security scanning"
  echo "  [c] Code Review       — review agents for all languages"
  echo "  [t] TDD               — test-driven development workflow"
  echo "  [p] Performance       — optimization and profiling agents"
  echo "  [d] Database          — SQL patterns, migrations, JPA"
  echo "  [o] DevOps            — Docker, deployment, CI/CD"
  echo "  [w] Documentation     — doc generation, README helpers"
  echo "  [k] Workflow          — PR workflow, autonomous loops"
  echo ""
  echo "  [m] Languages         — pick specific language rulesets"
  echo ""

  local _done=false
  while ! $_done; do
    printf "Select components (e.g. s,c,t or a for all): "
    read -r _resp
    _resp="${_resp#"${_resp%%[![:space:]]*}"}"
    _resp="${_resp%"${_resp##*[![:space:]]}"}"
    [[ -z "$_resp" ]] && continue

    if [[ "$_resp" == a ]]; then
      HAS_COMP=false; COMP_INPUT=""; _done=true; continue
    fi

    local _i; _i=0
    while [[ $_i -lt ${#_resp} ]]; do
      _c="${_resp:_i:1}"
      case "$_c" in
        s) _add_group security ;;
        c) _add_group codereview ;;
        t) _add_group tdd ;;
        p) _add_group performance ;;
        d) _add_group database ;;
        o) _add_group devops ;;
        w) _add_group documentation ;;
        k) _add_group workflow ;;
        m)
          _select_languages
          ;;
        *) printf "  Unknown option '%s'\n" "$_c" ;;
      esac
      _i=$((_i + 1))
    done
    HAS_COMP=true
    _done=true
  done
}

_select_languages() {
  echo ""
  echo "🌐 Language Rulesets"
  echo "─────────────────────"
  local _all_langs=(typescript python golang java kotlin cpp rust swift php dart)
  local _i
  for _i in "${!_all_langs[@]}"; do
    printf "  [%2d] %s\n" "$((_i + 1))" "${_all_langs[_i]}"
  done
  echo ""
  printf "Select languages (e.g. 1,3,5 or 0 for all): "
  read -r _resp
  _resp="${_resp#"${_resp%%[![:space:]]*}"}"
  _resp="${_resp%"${_resp##*[![:space:]]}"}"
  [[ -z "$_resp" ]] && return

  if [[ "$_resp" == 0 ]]; then
    SELECTED_LANG=(typescript python golang java kotlin cpp rust swift php dart)
    return
  fi

  local _new_lang=()
  local _input="$_resp"
  while [[ -n "$_input" ]]; do
    if [[ "$_input" == *,* ]]; then
      _tok="${_input%%,*}"
      _input="${_input#*,}"
    else
      _tok="$_input"; _input=""
    fi
    _tok="${_tok#"${_tok%%[![:space:]]*}"}"
    _tok="${_tok%"${_tok##*[![:space:]]}"}"
    [[ -z "$_tok" ]] && continue
    _idx=$((_tok - 1))
    if [[ $_idx -ge 0 ]] && [[ $_idx -lt ${#_all_langs[@]} ]]; then
      _add_lang "${_all_langs[_idx]}"
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --verbose)    VERBOSE=true; shift ;;
    --yes|-y)     YES_MODE=true; shift ;;
    --no-verify)  NO_VERIFY=true; shift ;;
    --select)     SELECT_MODE=true; shift ;;
    --components)
      if [[ -z "${2:-}" ]]; then
        echo "❌ --components requires an argument" >&2; exit 1
      fi
      COMP_INPUT="$2"; HAS_COMP=true; shift 2 ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Usage: $0 [--dry-run] [--verbose] [--yes] [--select] [--components GROUPS]" >&2
      exit 1
      ;;
  esac
done

# ─── Variables ──────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# ─── Detect if running from curl (no local repo) ───────────────────
if [[ ! -d "$REPO_DIR/.claude-plugin" ]]; then
  REPO_DIR=$(mktemp -d)
  if [[ ! -d "$REPO_DIR" ]]; then
    echo "❌ Failed to create temp directory (mktemp -d failed)" >&2
    exit 1
  fi
  if ! chmod 700 "$REPO_DIR"; then
    echo "❌ Failed to set permissions on temp directory" >&2
    exit 1
  fi
  IS_CURL_MODE=true
  echo "Cloning kalera-claude-code..."
  if ! git clone --depth 1 https://github.com/kalera-labs/kalera-claude-code.git "$REPO_DIR"; then
    echo "❌ Git clone failed — check network and try again" >&2
    exit 1
  fi
fi

is_tty() { [[ -t 0 ]]; }

ask() {
  local prompt="$1"
  local choice
  local count=0
  local max_attempts=10
  if is_tty; then
    echo ""
    echo "$prompt"
    while (( count < max_attempts )); do
      count=$((count + 1))
      select choice in Auto-fix Skip; do
        [[ -n "$choice" ]] && echo "$choice" && return
      done
    done
    echo "⏭  Too many invalid attempts — skipping."
    echo "Skip"
    return
  else
    echo "Auto-fix"  # non-interactive: default to auto-fix
  fi
}

resolve() {
  local action="$1"
  case "$action" in
    "Auto-fix") return 0 ;;
    *)          return 1 ;;
  esac
}

# ─── Header ────────────────────────────────────────────────────────
echo ""
echo "🚀 Kalera Claude Code — Installer"
echo "=================================="
echo ""

# ─── Component selection ──────────────────────────────────────────
if [[ "$SELECT_MODE" == true ]]; then
  _select_components
elif [[ "$HAS_COMP" == true ]]; then
  _parse_components "$COMP_INPUT"
fi
if [[ "$HAS_COMP" == true ]] && [[ ${#SELECTED_LANG[@]} -gt 0 ]]; then
  _lang_list=$(IFS=,; echo "${SELECTED_LANG[*]}")
  echo "📦 Selected languages: $_lang_list"
fi
if [[ "$HAS_COMP" == true ]] && [[ -n "$_SELECTED_GROUPS" ]]; then
  echo "📦 Selected groups: $_SELECTED_GROUPS"
fi

# ─── Check Claude CLI ───────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo "❌ Claude Code CLI not found."
  echo "   Install from: https://claude.ai/code"
  exit 1
fi

# ─── Detect existing installations ─────────────────────────────────
INSTALLED_PLUGINS=$(claude plugin list 2>/dev/null || echo "")
HAS_OLD_ECC=false
HAS_OLD_MUNIN=false
HAS_CONTEXT7=false
HAS_PLAYWRIGHT=false

ECC_OLD=$(echo "$INSTALLED_PLUGINS" | grep -iE "everything-claude-code.*affaan-m|@affaan-m/everything-claude-code|affaan-m/everything-claude-code" || true)
MUNIN_OLD=$(echo "$INSTALLED_PLUGINS" | grep -iE "munin-claude-code.*munin-ecosystem|@munin-ecosystem/munin-claude-code" || true)

[[ -n "$ECC_OLD" ]]    && HAS_OLD_ECC=true
[[ -n "$MUNIN_OLD" ]]  && HAS_OLD_MUNIN=true

if [[ -f "$SETTINGS_FILE" ]]; then
  grep -q "context7" "$SETTINGS_FILE" 2>/dev/null && HAS_CONTEXT7=true
  grep -q '"playwright"' "$SETTINGS_FILE" 2>/dev/null && HAS_PLAYWRIGHT=true
fi

# ─── Handle ECC conflict ───────────────────────────────────────────
if [[ "$HAS_OLD_ECC" == true ]]; then
  echo "⚠️  CONFLICT: Everything Claude Code detected from upstream"
  echo "   Source: affaan-m/everything-claude-code"
  echo "   → kalera-claude-code is a fork that replaces this."
  echo ""
  _choice=$(ask "  [1] Auto-fix  [2] Skip (keep old)")
  if resolve "$_choice"; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "   [dry-run] would: claude plugin uninstall everything-claude-code@affaan-m/everything-claude-code"
    else
      echo "   → Uninstalling old version..."
      _err=$(claude plugin uninstall everything-claude-code@affaan-m/everything-claude-code 2>&1) && \
        echo "   ✅ Old ECC removed." || \
        echo "   ⚠️  Uninstall warning: $_err"
    fi
  else
    echo "   ⏭  Skipped — old ECC kept."
  fi
  echo ""
fi

# ─── Handle Munin conflict ─────────────────────────────────────────
if [[ "$HAS_OLD_MUNIN" == true ]]; then
  echo "⚠️  CONFLICT: Munin detected from old source"
  echo "   Source: munin-ecosystem (kalera-labs/munin-for-agents)"
  echo "   → kalera-claude-code includes the latest Munin plugin."
  echo ""
  _choice=$(ask "  [1] Auto-fix  [2] Skip (keep old)")
  if resolve "$_choice"; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "   [dry-run] would: claude plugin uninstall munin-claude-code@munin-ecosystem"
    else
      echo "   → Uninstalling old version..."
      _err=$(claude plugin uninstall munin-claude-code@munin-ecosystem 2>&1) && \
        echo "   ✅ Old Munin removed." || \
        echo "   ⚠️  Uninstall warning: $_err"
    fi
  else
    echo "   ⏭  Skipped — old Munin kept."
  fi
  echo ""
fi

# ─── Handle Context7 MCP ───────────────────────────────────────────
if [[ "$HAS_CONTEXT7" == true ]]; then
  echo "⚠️  NOTE: Context7 MCP found in settings.json"
  echo "   → kalera-claude-code removes its own copy (you already have it)."
  echo ""
  _choice=$(ask "  [1] Auto-fix (remove from kalera-claude-code)  [2] Skip")
  if resolve "$_choice"; then
    # Remove context7 entries from mcp-configs/mcp-servers.json
    if [[ -f "$REPO_DIR/mcp-configs/mcp-servers.json" ]]; then
      if grep -q '"context7"' "$REPO_DIR/mcp-configs/mcp-servers.json"; then
        echo "   ✅ Will skip context7 in kalera-claude-code MCP configs."
      fi
    fi
    echo "   ⏭  Context7 in settings.json untouched."
  else
    echo "   ⏭  Skipped."
  fi
  echo ""
fi

# ─── Handle Playwright MCP ─────────────────────────────────────────
if [[ "$HAS_PLAYWRIGHT" == true ]]; then
  echo "⚠️  NOTE: Playwright MCP found in settings.json"
  echo "   → kalera-claude-code removes its own copy (you already have it)."
  echo ""
  _choice=$(ask "  [1] Auto-fix (remove from kalera-claude-code)  [2] Skip")
  if resolve "$_choice"; then
    echo "   ✅ Will skip Playwright in kalera-claude-code MCP configs."
  else
    echo "   ⏭  Skipped."
  fi
  echo ""
fi

echo "✅ Conflict check complete."
echo ""

# ─── Add marketplace ───────────────────────────────────────────────
echo "📦 Adding Kalera marketplace..."
if [[ "$DRY_RUN" == true ]]; then
  echo "   [dry-run] would: claude plugin marketplace add kalera-labs/kalera-claude-code"
else
  _mkt_err=$(claude plugin marketplace add kalera-labs/kalera-claude-code 2>&1)
  _mkt_rc=$?
  if [[ $_mkt_rc -ne 0 ]]; then
    echo "   ⚠️  Marketplace add failed (rc=$_mkt_rc): $_mkt_err"
    echo "   → Will attempt direct plugin install anyway..."
  fi
fi

# ─── Install ECC ───────────────────────────────────────────────────
echo "⚙️  Installing kalera-claude-code..."
if [[ "$DRY_RUN" == true ]]; then
  echo "   [dry-run] would: claude plugin install kalera-claude-code@kalera-claude-code"
else
  _ecc1_err=$(claude plugin install kalera-claude-code@kalera-claude-code 2>&1)
  _ecc1_rc=$?
  if [[ $_ecc1_rc -eq 0 ]]; then
    echo "   ✅ kalera-claude-code installed"
  elif [[ $_ecc1_rc -eq 2 ]]; then
    echo "   ❌ Plugin 'kalera-claude-code' not found in marketplace 'kalera-labs/kalera-claude-code'"
  elif [[ $_ecc1_rc -eq 3 ]]; then
    echo "   ❌ Plugin 'kalera-claude-code' already installed — skip or uninstall first"
  else
    echo "   ❌ Install failed (rc=$_ecc1_rc):"
    [[ -n "$_ecc1_err" ]] && echo "      $_ecc1_err"
  fi
fi

# ─── Install Munin ─────────────────────────────────────────────────
echo "🧠 Installing Munin memory plugin..."
if [[ "$DRY_RUN" == true ]]; then
  echo "   [dry-run] would: claude plugin install munin-claude-code@kalera-claude-code"
else
  _mun_err=$(claude plugin install munin-claude-code@kalera-claude-code 2>&1)
  _mun_rc=$?
  if [[ $_mun_rc -ne 0 ]]; then
    # Fallback: try munin-ecosystem marketplace (where it was previously published)
    _mun_err2=$(claude plugin install munin-claude-code@munin-ecosystem 2>&1)
    _mun_rc2=$?
    if [[ $_mun_rc2 -eq 0 ]]; then
      _mun_rc=0
      _mun_err=""
    else
      _mun_err="primary marketplace: $_mun_err; fallback marketplace: $_mun_err2"
    fi
  fi
  if [[ $_mun_rc -eq 0 ]]; then
    echo "   ✅ munin-claude-code installed"
  elif [[ $_mun_rc -eq 2 ]]; then
    echo "   ❌ Plugin not found on marketplace 'kalera-labs/kalera-claude-code'"
  elif [[ $_mun_rc -eq 3 ]]; then
    echo "   ❌ Plugin already installed — skip this step or uninstall first"
  else
    echo "   ❌ Install failed (rc=$_mun_rc): $_mun_err"
  fi
fi

# ─── Install rules ────────────────────────────────────────────────
echo ""
echo "📋 Installing rules..."
if [[ "$DRY_RUN" == true ]]; then
  echo "   [dry-run] would: copy rules/common + selected language rulesets to ~/.claude/rules/"
elif [[ -d "$REPO_DIR/rules" ]]; then
  mkdir -p ~/.claude/rules

  if [[ -d "$REPO_DIR/rules/common" ]]; then
    for _f in "$REPO_DIR/rules/common"/*; do
      [[ -e "$_f" ]] || continue
      _basename=$(basename "$_f")
      if [[ -f "$HOME/.claude/rules/$_basename" ]]; then
        cp -f "$_f" "$HOME/.claude/rules/${_basename}.kalera.bak"
        echo "   📝 rules/common/$_basename (backed up existing → .kalera.bak)"
      else
        cp -f "$_f" "$HOME/.claude/rules/$_basename"
      fi
    done
    echo "   ✅ rules/common/"
  fi

  # Default to all languages if nothing selected
  if [[ ${#SELECTED_LANG[@]} -eq 0 ]]; then
    SELECTED_LANG=(typescript python golang java kotlin cpp rust swift php dart)
  fi
  for lang in "${SELECTED_LANG[@]}"; do
    if [[ -d "$REPO_DIR/rules/$lang" ]]; then
      mkdir -p ~/.claude/rules/$lang
      for _f in "$REPO_DIR/rules/$lang"/*; do
        [[ -e "$_f" ]] || continue
        _basename=$(basename "$_f")
        if [[ -f "$HOME/.claude/rules/$lang/$_basename" ]]; then
          cp -f "$_f" "$HOME/.claude/rules/$lang/${_basename}.kalera.bak"
          echo "   📝 rules/$lang/$_basename (backed up existing → .kalera.bak)"
        else
          cp -f "$_f" "$HOME/.claude/rules/$lang/$_basename"
        fi
      done
      echo "   ✅ rules/$lang/"
    fi
  done
fi

# ─── Done ──────────────────────────────────────────────────────────
echo ""
echo "✅ Kalera Claude Code installed!"
[[ "$DRY_RUN" == true ]] && echo "   (dry-run — no changes made)"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code"
echo "  2. Sign up at https://munin.kalera.ai (free)"
echo "  3. Run: /munin:projectid"
echo "     → It will show current ID or prompt you to set it"
echo ""
echo "Docs: https://github.com/kalera-labs/kalera-claude-code"

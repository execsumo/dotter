#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUI="$REPO_ROOT/bin/dotfiles-tui"

FAILURES=0
TOTAL=0

run_test() {
  local name="$1"
  local func="$2"
  TOTAL=$((TOTAL + 1))
  
  echo -n "TEST: $name ... "
  
  local out
  if out="$( (set -e; $func) 2>&1 )"; then
    echo "PASS"
  else
    echo "FAIL"
    echo "$out" | sed 's/^/  /'
    FAILURES=$((FAILURES + 1))
  fi
}

test_tui_bash_syntax() {
  bash -n "$TUI" && /bin/bash -n "$TUI"
}

test_tui_bash_4_syntax_absent() {
  if grep -vE '^[[:space:]]*#' "$TUI" | grep -E '(\$\{.*,,|\$\{.*\^\^|declare -A|mapfile|readarray|&>>)'; then
    echo "Found bash 4+ syntax in dotfiles-tui"
    return 1
  fi
}

test_fzf_absence_handling() {
  local out code=0
  out="$(env PATH=/usr/bin:/bin "$TUI" browse 2>&1)" || code=$?
  [ "$code" -ne 0 ] || { echo "Expected non-zero exit code"; return 1; }
  echo "$out" | grep -qi "fzf is required" || { echo "Missing fzf install hint"; return 1; }
}

test_no_tty_handling() {
  local out code=0
  out="$("$TUI" browse </dev/null 2>&1)" || code=$?
  [ "$code" -ne 0 ] || { echo "Expected non-zero exit code"; return 1; }
  echo "$out" | grep -qi "requires an interactive TTY" || { echo "Missing TTY error message"; return 1; }
}

test_dry_run_narrow() {
  local out
  out="$(DOTFILES_TUI_DRY_RUN=1 "$TUI" narrow mydir file1.txt file2.txt)"
  echo "$out" | grep -q "^WOULD-RUN: dotfiles rm mydir" || { echo "Missing WOULD-RUN: dotfiles rm"; return 1; }
  echo "$out" | grep -q "^WOULD-RUN: dotfiles add ~/mydir/file1.txt" || { echo "Missing WOULD-RUN: dotfiles add file1"; return 1; }
  echo "$out" | grep -q "^WOULD-RUN: dotfiles add ~/mydir/file2.txt" || { echo "Missing WOULD-RUN: dotfiles add file2"; return 1; }
  if echo "$out" | grep -q "\-\-yes"; then
    echo "Found unexpected --yes flag in dry-run output"
    return 1
  fi
}

test_dry_run_browse_rm() {
  local out
  out="$(DOTFILES_TUI_DRY_RUN=1 "$TUI" browse rm .zshrc)"
  echo "$out" | grep -q "^WOULD-RUN: dotfiles rm .zshrc" || return 1
}

test_dry_run_discover() {
  local out
  out="$(DOTFILES_TUI_DRY_RUN=1 "$TUI" discover ~/.zshrc)"
  echo "$out" | grep -q "^WOULD-RUN: dotfiles add /" || return 1
}

test_dry_run_status_sync() {
  local out
  out="$(DOTFILES_TUI_DRY_RUN=1 "$TUI" status sync "commit msg")"
  echo "$out" | grep -q "^WOULD-RUN: dotfiles sync -m commit msg" || return 1
}

run_test "TUI syntax check (bash & bash 3.2)" test_tui_bash_syntax
run_test "TUI bash 4+ syntax absent" test_tui_bash_4_syntax_absent
run_test "fzf absence handling" test_fzf_absence_handling
run_test "no-TTY handling" test_no_tty_handling
run_test "Dry-run narrow choke-point" test_dry_run_narrow
run_test "Dry-run browse rm" test_dry_run_browse_rm
run_test "Dry-run discover" test_dry_run_discover
run_test "Dry-run status sync" test_dry_run_status_sync

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES of $TOTAL TUI tests failed."
  exit 1
else
  echo "All TUI tests passed."
  exit 0
fi

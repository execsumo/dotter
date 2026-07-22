#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/bin/dotfiles"
SCAN_BIN="$REPO_ROOT/bin/dotfiles-scan"

FAILURES=0
TOTAL=0

run_test() {
  local name="$1"
  local func="$2"
  TOTAL=$((TOTAL + 1))
  
  export TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  export DOTFILES_DIR="$TEST_DIR/dotfiles"
  export REMOTE_DIR="$TEST_DIR/remote.git"
  
  mkdir -p "$HOME"
  git init --bare "$REMOTE_DIR" >/dev/null 2>&1
  
  export GIT_CONFIG_GLOBAL="$TEST_DIR/gitconfig"
  git config --global user.name "Test User"
  git config --global user.email "test@example.com"
  
  echo -n "TEST: $name ... "
  
  local out
  if out="$( (set -e; $func) 2>&1 )"; then
    echo "PASS"
  else
    echo "FAIL"
    echo "$out" | sed 's/^/  /'
    FAILURES=$((FAILURES + 1))
  fi
  
  rm -rf "$TEST_DIR"
}

# Helper to create a directory with various risky/unsafe files
make_risky_dir() {
  local d="$1"
  mkdir -p "$d/nested"
  echo '{"token":"secret_key"}' > "$d/auth.json"
  echo 'setting = 1'         > "$d/config.toml"
  echo 'log entry'           > "$d/app.log"
  : > "$d/data.sqlite3"
  dd if=/dev/null of="$d/sparse_60m.bin" bs=1 count=0 seek=60000000 2>/dev/null
  ln -s /opt/outside/thing "$d/nested/stray_symlink"
  mkfifo "$d/runtime.sock" 2>/dev/null || true
}

test_scan_bash_syntax() {
  bash -n "$SCAN_BIN" && /bin/bash -n "$SCAN_BIN"
}

test_scan_bash_4_syntax_absent() {
  if grep -vE '^[[:space:]]*#' "$SCAN_BIN" | grep -E '(\$\{.*,,|\$\{.*\^\^|declare -A|mapfile|readarray|&>>)'; then
    echo "Found bash 4+ syntax in dotfiles-scan"
    return 1
  fi
}

# 1. candidates never proposes a path already in the manifest
test_candidates_omits_manifest_entries() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "export PATH" > "$HOME/.zshrc"
  "$BIN" add "$HOME/.zshrc" >/dev/null

  local out
  out="$("$SCAN_BIN" candidates)"

  if printf '%s\n' "$out" | grep -q '|\.zshrc|'; then
    echo "candidates proposed .zshrc which is already in manifest!"
    return 1
  fi
}

# 2. candidates emits only well-formed 4-field lines with kind in {file,dir}
test_candidates_format_wellformed() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "export PATH" > "$HOME/.zshrc"
  mkdir -p "$HOME/.config/alacritty"
  echo "alacritty = 1" > "$HOME/.config/alacritty/alacritty.toml"

  local out
  out="$("$SCAN_BIN" candidates)"

  if [ -z "$out" ]; then
    echo "candidates returned empty output on fixture"
    return 1
  fi

  local bad_fields bad_kind
  bad_fields="$(printf '%s\n' "$out" | awk -F'|' 'NF != 4')"
  if [ -n "$bad_fields" ]; then
    echo "candidates line(s) do not have exactly 4 fields:"
    printf '%s\n' "$bad_fields"
    return 1
  fi

  bad_kind="$(printf '%s\n' "$out" | awk -F'|' '$1 != "file" && $1 != "dir"')"
  if [ -n "$bad_kind" ]; then
    echo "candidates line(s) have invalid kind (not file or dir):"
    printf '%s\n' "$bad_kind"
    return 1
  fi
}

# 3. candidates does not propose .ssh as a dir entry
test_candidates_no_ssh_dir() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$HOME/.ssh"
  echo "Host github.com" > "$HOME/.ssh/config"
  echo "key" > "$HOME/.ssh/id_rsa"

  local out
  out="$("$SCAN_BIN" candidates)"

  if printf '%s\n' "$out" | grep -q '^dir|\.ssh|'; then
    echo "candidates proposed .ssh as a dir entry!"
    return 1
  fi

  # Proposing .ssh/config as a file entry is allowed and expected
  if ! printf '%s\n' "$out" | grep -q '|\.ssh/config|'; then
    echo "candidates missed .ssh/config file entry"
    return 1
  fi
}

# 4. expand on a fixture dir lists every regular file in it, and only those
test_expand_lists_regular_files() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$HOME/.config/tool/subdir"
  echo "a" > "$HOME/.config/tool/file1.txt"
  echo "b" > "$HOME/.config/tool/subdir/file2.txt"

  local out
  out="$("$SCAN_BIN" expand .config/tool)"

  local nlines
  nlines="$(printf '%s\n' "$out" | grep -c '^file|\.config/tool/')"
  [ "$nlines" -eq 2 ] || { echo "expected 2 files, got $nlines"; return 1; }

  printf '%s\n' "$out" | grep -q '|\.config/tool/file1\.txt|' || return 1
  printf '%s\n' "$out" | grep -q '|\.config/tool/subdir/file2\.txt|' || return 1
}

# 5. expand marks auth.json with secret flag and plain config.toml with -
test_expand_flags_secret_and_clean() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$HOME/.config/app"
  echo '{"token":"123"}' > "$HOME/.config/app/auth.json"
  echo 'setting = true'   > "$HOME/.config/app/config.toml"

  local out
  out="$("$SCAN_BIN" expand .config/app)"

  local auth_line config_line
  auth_line="$(printf '%s\n' "$out" | grep '|\.config/app/auth\.json|')"
  config_line="$(printf '%s\n' "$out" | grep '|\.config/app/config\.toml|')"

  [ -n "$auth_line" ] || { echo "missing auth.json in expand"; return 1; }
  [ -n "$config_line" ] || { echo "missing config.toml in expand"; return 1; }

  echo "$auth_line" | grep -q '|secret|' || { echo "auth.json not flagged secret: $auth_line"; return 1; }
  echo "$config_line" | grep -q '|-|' || { echo "config.toml not marked clean (-): $config_line"; return 1; }
}

# 5b. expand on a tracked dir (symlink in $HOME -> real dir in repo) lists all files with sizes
test_expand_tracked_symlinked_dir_entry() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$HOME/.config/tool/subdir"
  printf "hello" > "$HOME/.config/tool/file1.txt"
  printf "world" > "$HOME/.config/tool/subdir/file2.txt"

  # Add the dir entry to dotfiles repo — $HOME/.config/tool becomes a symlink!
  "$BIN" add --yes "$HOME/.config/tool" >/dev/null

  [ -L "$HOME/.config/tool" ] || { echo "$HOME/.config/tool is not a symlink after add"; return 1; }

  local out
  out="$("$SCAN_BIN" expand .config/tool)"

  local nlines
  nlines="$(printf '%s\n' "$out" | grep -c '^file|\.config/tool/')"
  [ "$nlines" -eq 2 ] || { echo "expected 2 files from tracked dir expand, got $nlines"; return 1; }

  printf '%s\n' "$out" | grep -q 'file|\.config/tool/file1\.txt|-|5' || { echo "file1 missing or bad size: $out"; return 1; }
  printf '%s\n' "$out" | grep -q 'file|\.config/tool/subdir/file2\.txt|-|5' || { echo "file2 missing or bad size: $out"; return 1; }
}

# 6. audit output is byte-identical to dotfiles audit --porcelain for the same path
test_audit_byte_identical() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  make_risky_dir "$HOME/risky"

  local porcelain_out scan_audit_out
  porcelain_out="$("$BIN" audit --porcelain "$HOME/risky")"
  scan_audit_out="$("$SCAN_BIN" audit "$HOME/risky")"

  if [ "$porcelain_out" != "$scan_audit_out" ]; then
    echo "audit output is not byte-identical to dotfiles audit --porcelain!"
    echo "dotfiles audit --porcelain:"
    printf '%s\n' "$porcelain_out"
    echo "dotfiles-scan audit:"
    printf '%s\n' "$scan_audit_out"
    return 1
  fi
}

# 7. Fixture dir with auth.json, 60MB sparse file, socket, and nested .git yields corresponding flags
test_audit_catches_all_unsafe_cases() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  make_risky_dir "$HOME/risky"
  mkdir -p "$HOME/risky/.git"

  local out
  out="$("$SCAN_BIN" audit "$HOME/risky")"

  local flag
  for flag in secret large socket log db foreign-symlink nested-git; do
    if ! printf '%s\n' "$out" | awk -F'|' -v f="$flag" '$2==f' | grep -q .; then
      echo "missing audit flag: $flag"
      printf '%s\n' "$out"
      return 1
    fi
  done
}

# 8. Exit code is 0 for a scan that finds problems, non-zero for a scan that cannot run (e.g. no repo)
test_exit_codes() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  make_risky_dir "$HOME/risky"

  local code=0
  "$SCAN_BIN" candidates >/dev/null 2>&1 || code=$?
  [ "$code" -eq 0 ] || { echo "candidates failed with exit code $code"; return 1; }

  code=0
  "$SCAN_BIN" audit "$HOME/risky" >/dev/null 2>&1 || code=$?
  [ "$code" -eq 0 ] || { echo "audit failed with exit code $code"; return 1; }

  # Non-zero exit code when dotfiles repo missing or path unreadable
  local bad_code=0
  rm -rf "$DOTFILES_DIR"
  "$SCAN_BIN" expand .nonexistent_path >/dev/null 2>&1 || bad_code=$?
  [ "$bad_code" -ne 0 ] || { echo "expand on missing path returned exit code 0"; return 1; }
}

run_test "Scanner syntax check (bash & bash 3.2)" test_scan_bash_syntax
run_test "Scanner bash 4+ syntax absent" test_scan_bash_4_syntax_absent
run_test "Candidates omits manifest entries" test_candidates_omits_manifest_entries
run_test "Candidates format well-formed (4 fields, valid kind)" test_candidates_format_wellformed
run_test "Candidates does not propose .ssh as dir" test_candidates_no_ssh_dir
run_test "Expand lists regular files recursively" test_expand_lists_regular_files
run_test "Expand flags secret (auth.json) and clean (-)" test_expand_flags_secret_and_clean
run_test "Expand on tracked symlinked dir entry" test_expand_tracked_symlinked_dir_entry
run_test "Audit output byte-identical to dotfiles audit --porcelain" test_audit_byte_identical
run_test "Audit catches all unsafe cases (auth, 60MB, socket, git)" test_audit_catches_all_unsafe_cases
run_test "Exit codes (0 on findings, non-zero on scan failure)" test_exit_codes

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES of $TOTAL scanner tests failed."
  exit 1
else
  echo "All scanner tests passed."
  exit 0
fi
